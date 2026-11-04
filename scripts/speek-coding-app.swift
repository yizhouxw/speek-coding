#!/usr/bin/env swift

import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import Darwin
import Foundation

// SpeekCoding's native, permission-bearing agent.  The surrounding installer
// compiles this source into SpeekCoding.app and supplies its Info.plist.  Keep
// microphone capture, TCC inspection, clipboard access, and event posting in
// this process so macOS presents one stable product identity to the user.

private let agentName = "SpeekCoding"
private let agentBundleIdentifier = "com.speek.coding"
private let protocolVersion = 1
private let stateDirectoryURL = URL(fileURLWithPath: "/tmp/speek-coding-\(geteuid())", isDirectory: true)
private let socketURL = stateDirectoryURL.appendingPathComponent("agent.sock")
private let ipcTokenURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
	.appendingPathComponent(".config/speek-coding/ipc-token")

private typealias JSONObject = [String: Any]
private typealias AgentCompletion = (JSONObject) -> Void

private struct AgentFailure: LocalizedError {
	let code: String
	let message: String

	var errorDescription: String? { message }
}

private func failure(_ code: String, _ message: String) -> AgentFailure {
	AgentFailure(code: code, message: message)
}

private func errorResponse(command: String, error: Error, state: String) -> JSONObject {
	let agentError = error as? AgentFailure
	return [
		"ok": false,
		"command": command,
		"state": state,
		"error": [
			"code": agentError?.code ?? "INTERNAL_ERROR",
			"message": agentError?.message ?? error.localizedDescription,
		],
	]
}

private func stringValue(_ value: Any?) -> String? {
	if let value = value as? String { return value }
	if let value = value as? NSNumber { return value.stringValue }
	return nil
}

private func doubleValue(_ value: Any?) -> Double? {
	if let value = value as? NSNumber { return value.doubleValue }
	if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
	return nil
}

private func boolValue(_ value: Any?) -> Bool? {
	if let value = value as? Bool { return value }
	if let value = value as? NSNumber { return value.boolValue }
	guard let text = value as? String else { return nil }
	switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
	case "1", "true", "yes", "on": return true
	case "0", "false", "no", "off": return false
	default: return nil
	}
}

private func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
	let left = Array(lhs.utf8)
	let right = Array(rhs.utf8)
	guard left.count == right.count else { return false }
	var difference: UInt8 = 0
	for index in left.indices { difference |= left[index] ^ right[index] }
	return difference == 0
}

private func readIPCToken() -> String {
	(try? String(contentsOf: ipcTokenURL, encoding: .utf8))?
		.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func isLoopbackHost(_ host: String?) -> Bool {
	guard let normalized = host?.lowercased() else { return false }
	return normalized == "localhost" || normalized == "::1" || normalized.hasPrefix("127.")
}

private extension Data {
	mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
		var littleEndian = value.littleEndian
		Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
	}
}

// MARK: - Configuration

private func decodeShellValue(_ rawValue: Substring) -> String {
	let text = String(rawValue).trimmingCharacters(in: .whitespaces)
	var result = ""
	var quote: Character?
	var escaped = false
	for character in text {
		if escaped {
			result.append(character)
			escaped = false
			continue
		}
		if character == "\\" && quote != "'" {
			escaped = true
			continue
		}
		if character == "'" || character == "\"" {
			if quote == nil {
				quote = character
				continue
			}
			if quote == character {
				quote = nil
				continue
			}
		}
		result.append(character)
	}
	if escaped { result.append("\\") }
	return result
}

private func readEnvironmentFile(at url: URL) -> [String: String] {
	guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
	var values: [String: String] = [:]
	for rawLine in contents.split(whereSeparator: \Character.isNewline) {
		let line = rawLine.trimmingCharacters(in: .whitespaces)
		guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
		var key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
		if key.hasPrefix("export ") {
			key = String(key.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
		}
		guard !key.isEmpty else { continue }
		values[key] = decodeShellValue(line[line.index(after: separator)...])
	}
	return values
}

private func configFileURL() -> URL {
	let env = ProcessInfo.processInfo.environment
	let home = env["HOME"] ?? NSHomeDirectory()
	let directory = env["SPEEK_CONFIG_DIR"] ?? env["DJI_CONFIG_DIR"]
		?? URL(fileURLWithPath: home).appendingPathComponent(".config/speek-coding").path
	return URL(fileURLWithPath: env["SPEEK_CONFIG_FILE"] ?? env["DJI_CONFIG_FILE"]
		?? URL(fileURLWithPath: directory).appendingPathComponent("config.env").path)
}

private func audioInputDevices() -> [AVCaptureDevice] {
	if #available(macOS 14.0, *) {
		return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
	}
	return AVCaptureDevice.devices(for: .audio)
}

private func saveInputDevice(_ name: String) throws {
	guard !name.contains("\n"), !name.contains("\r") else {
		throw failure("INVALID_DEVICE_NAME", "The microphone name contains an unsupported line break.")
	}
	let escaped = name.replacingOccurrences(of: "'", with: "'\"'\"'")
	try saveConfigValues(["SPEEK_AUDIO_INPUT_DEVICE_NAME": "'\(escaped)'", "SPEEK_AUDIO_INPUT_DEVICE_INDEX": "''"])
}

private func saveConfigValues(_ values: [String: String]) throws {
	let url = configFileURL()
	let directory = url.deletingLastPathComponent()
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
	let existing: String
	if FileManager.default.fileExists(atPath: url.path) { existing = try String(contentsOf: url, encoding: .utf8) }
	else { existing = "" }
	let keys = Set(values.keys)
	var lines = existing.components(separatedBy: .newlines).filter { line in
		let key = line.split(separator: "=", maxSplits: 1).first.map(String.init)?
			.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "") ?? ""
		return !keys.contains(key)
	}
	while lines.last == "" { lines.removeLast() }
	for key in values.keys.sorted() { lines.append("\(key)=\(values[key]!)") }
	try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
	try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

// MARK: - Menu localization

private enum MenuLanguage: String, CaseIterable {
	case system
	case simplifiedChinese = "zh-Hans"
	case traditionalChinese = "zh-Hant"
	case english = "en"

	static let defaultsKey = "menuLanguage"

	static func selected(in defaults: UserDefaults = .standard) -> MenuLanguage {
		MenuLanguage(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
	}

	func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> MenuLanguage {
		guard self == .system else { return self }
		for identifier in preferredLanguages {
			let parts = identifier.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-")
			if parts.first == "en" { return .english }
			guard parts.first == "zh" else { continue }
			if parts.contains("hans") { return .simplifiedChinese }
			if parts.contains("hant") || parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) {
				return .traditionalChinese
			}
			return .simplifiedChinese
		}
		return .english
	}

	var displayName: String {
		switch self {
		case .system: return menuText(.followSystem)
		case .simplifiedChinese: return "简体中文"
		case .traditionalChinese: return "繁體中文"
		case .english: return "English"
		}
	}
}

private enum MenuText: String, CaseIterable {
	case microphoneInput = "Microphone Input"
	case systemMicrophone = "System Default Microphone"
	case disconnected = "%@ (disconnected)"
	case featureSettings = "Feature Settings"
	case autoSend = "Auto-send (press Return after pasting)"
	case autoSendHelp = "When checked, paste and press Return. When unchecked, paste only."
	case language = "Language"
	case followSystem = "Follow macOS"
	case languageHelp = "Change the menu language without restarting the app."
	case permissionSettings = "Permissions"
	case allowed = "Allowed"
	case clickToAllow = "Click to Allow"
	case restricted = "Restricted by System"
	case notAllowed = "Not Allowed"
	case microphoneStatus = "Microphone: %@…"
	case microphoneHelp = "Allow SpeekCoding to record audio"
	case accessibilityRequired = "Allow Accessibility"
	case eventPostingRequired = "Allow Simulated Keystrokes"
	case deliveryStatus = "Automatic Paste and Send: %@…"
	case deliveryHelp = "Copy transcription to the clipboard, then paste it automatically. Auto-send also presses Return. Clipboard-only mode does not require this permission."
	case karabinerDownloading = "Karabiner-Elements: Downloading Installer…"
	case karabinerInstalled = "Karabiner-Elements: Installed (Open Settings)…"
	case karabinerMissing = "Karabiner-Elements: Not Installed (Download)…"
	case karabinerHelp = "Global shortcuts and the DJI Mic button require Karabiner-Elements"
	case quit = "Quit SpeekCoding"
	case karabinerOpenFailed = "Could not open Karabiner-Elements."
	case karabinerInstall = "Install Karabiner-Elements"
	case karabinerGuide = "SpeekCoding uses Karabiner-Elements for global shortcuts and the DJI Mic button. The installer will be downloaded from the official website and opened. After installation, open Karabiner-Elements, allow background services, Accessibility, and Input Monitoring as prompted, then run SpeekCoding setup again."
	case downloadInstaller = "Download Installer"
	case cancel = "Cancel"
	case downloadFailed = "Download failed. Check your network connection."
	case signatureInvalid = "Installer signature verification failed."
	case installerOpenFailed = "Could not open the Karabiner-Elements installer."
	case installerFailed = "Could not prepare or verify the installer."
	case karabinerError = "Could Not Prepare Karabiner-Elements"
	case websiteSuggestion = "%@\nYou can download and install it from the official website."
	case openWebsite = "Open Website"
	case microphoneSaveFailed = "Could Not Save Microphone Settings"
	case autoSendSaveFailed = "Could Not Save Auto-send Settings"

	var chinese: (simplified: String, traditional: String) {
		switch self {
		case .microphoneInput: return ("麦克风输入", "麥克風輸入")
		case .systemMicrophone: return ("系统默认麦克风", "系統預設麥克風")
		case .disconnected: return ("%@（未连接）", "%@（未連接）")
		case .featureSettings: return ("功能设置", "功能設定")
		case .autoSend: return ("自动发送（粘贴时附加回车）", "自動傳送（貼上時附加 Return）")
		case .autoSendHelp: return ("勾选时粘贴后按回车；取消勾选时仅粘贴。", "勾選時貼上後按 Return；取消勾選時僅貼上。")
		case .language: return ("语言", "語言")
		case .followSystem: return ("跟随 macOS", "跟隨 macOS")
		case .languageHelp: return ("更改菜单语言，无需重启应用。", "變更選單語言，無需重新啟動應用程式。")
		case .permissionSettings: return ("权限设置", "權限設定")
		case .allowed: return ("已允许", "已允許")
		case .clickToAllow: return ("点击授权", "點按以授權")
		case .restricted: return ("受系统限制", "受系統限制")
		case .notAllowed: return ("未允许", "未允許")
		case .microphoneStatus: return ("麦克风：%@…", "麥克風：%@…")
		case .microphoneHelp: return ("允许 SpeekCoding 录制语音", "允許 SpeekCoding 錄製語音")
		case .accessibilityRequired: return ("需要允许控制电脑", "需要允許控制電腦")
		case .eventPostingRequired: return ("需要允许模拟按键", "需要允許模擬按鍵")
		case .deliveryStatus: return ("自动粘贴和发送：%@…", "自動貼上與傳送：%@…")
		case .deliveryHelp: return ("转写文字先复制到剪贴板，再自动粘贴；发送模式还会按回车。仅复制到剪贴板无需此权限。", "轉寫文字先複製到剪貼簿，再自動貼上；傳送模式還會按 Return。僅複製到剪貼簿無需此權限。")
		case .karabinerDownloading: return ("Karabiner-Elements：正在下载安装包…", "Karabiner-Elements：正在下載安裝程式…")
		case .karabinerInstalled: return ("Karabiner-Elements：已安装（打开设置）…", "Karabiner-Elements：已安裝（開啟設定）…")
		case .karabinerMissing: return ("Karabiner-Elements：未安装（下载安装）…", "Karabiner-Elements：未安裝（下載安裝）…")
		case .karabinerHelp: return ("全局按键和 DJI Mic 按钮需要 Karabiner-Elements", "全域快捷鍵與 DJI Mic 按鈕需要 Karabiner-Elements")
		case .quit: return ("退出 SpeekCoding", "結束 SpeekCoding")
		case .karabinerOpenFailed: return ("无法打开 Karabiner-Elements。", "無法開啟 Karabiner-Elements。")
		case .karabinerInstall: return ("安装 Karabiner-Elements", "安裝 Karabiner-Elements")
		case .karabinerGuide: return ("SpeekCoding 使用 Karabiner-Elements 接收全局按键和 DJI Mic 按钮。将从官方网站下载并打开安装器。安装后请打开 Karabiner-Elements，按提示允许后台服务、辅助功能和输入监控，再重新运行 SpeekCoding 设置。", "SpeekCoding 使用 Karabiner-Elements 接收全域快捷鍵與 DJI Mic 按鈕。將從官方網站下載並開啟安裝程式。安裝後請開啟 Karabiner-Elements，依提示允許背景服務、輔助使用與輸入監控，再重新執行 SpeekCoding 設定。")
		case .downloadInstaller: return ("下载安装包", "下載安裝程式")
		case .cancel: return ("取消", "取消")
		case .downloadFailed: return ("下载未成功，请检查网络连接。", "下載失敗，請檢查網路連線。")
		case .signatureInvalid: return ("安装包签名验证失败。", "安裝程式簽章驗證失敗。")
		case .installerOpenFailed: return ("无法打开 Karabiner-Elements 安装器。", "無法開啟 Karabiner-Elements 安裝程式。")
		case .installerFailed: return ("无法准备或验证安装包。", "無法準備或驗證安裝程式。")
		case .karabinerError: return ("无法准备 Karabiner-Elements", "無法準備 Karabiner-Elements")
		case .websiteSuggestion: return ("%@\n可以从官方网站下载并安装。", "%@\n可以從官方網站下載並安裝。")
		case .openWebsite: return ("打开官网", "開啟官網")
		case .microphoneSaveFailed: return ("无法保存麦克风设置", "無法儲存麥克風設定")
		case .autoSendSaveFailed: return ("无法保存自动发送设置", "無法儲存自動傳送設定")
		}
	}

	func text(in language: MenuLanguage) -> String {
		switch language {
		case .simplifiedChinese: return chinese.simplified
		case .traditionalChinese: return chinese.traditional
		case .english, .system: return rawValue
		}
	}
}

private func menuText(_ key: MenuText, _ arguments: CVarArg...) -> String {
	let text = key.text(in: MenuLanguage.selected().resolved())
	return arguments.isEmpty ? text : String(format: text, arguments: arguments)
}

private struct AgentConfig {
	let asrAPIURL: String
	let asrModel: String
	let asrLanguage: String
	let asrPrompt: String
	let asrAPIKey: String
	let asrTimeout: TimeInterval
	let fakeTranscript: String
	let audioInputDeviceName: String
	let audioInputDeviceIndex: String
	let audioSampleRate: Double
	let deliveryMode: String
	let silenceGuard: Bool
	let silenceMinimumRMSDB: Double
	let silenceMinimumPeakDB: Double
	let readyOverlayEnabled: Bool
	let hudBinaryPath: String
	let audioFeedbackEnabled: Bool
	let feedbackSoundName: String

	static func load(overrides request: JSONObject = [:]) -> AgentConfig {
		let processEnvironment = ProcessInfo.processInfo.environment
		let home = processEnvironment["HOME"] ?? NSHomeDirectory()
		var values = readEnvironmentFile(at: configFileURL())
		for (key, value) in processEnvironment { values[key] = value }

		var requestValues: JSONObject = request["config"] as? JSONObject ?? [:]
		for (key, value) in request where key != "config" { requestValues[key] = value }

		func value(_ requestKeys: [String], _ environmentKey: String, default fallback: String) -> String {
			for key in requestKeys {
				if let found = stringValue(requestValues[key]) { return found }
			}
			return values[environmentKey] ?? fallback
		}

		func boolean(_ requestKeys: [String], _ environmentKey: String, default fallback: Bool) -> Bool {
			for key in requestKeys {
				if let found = boolValue(requestValues[key]) { return found }
			}
			return boolValue(values[environmentKey]) ?? fallback
		}

		func number(_ requestKeys: [String], _ environmentKey: String, default fallback: Double) -> Double {
			for key in requestKeys {
				if let found = doubleValue(requestValues[key]) { return found }
			}
			return doubleValue(values[environmentKey]) ?? fallback
		}

		let apiKeyEnvironmentName = value(
			["asrApiKeyEnv", "asr_api_key_env"],
			"SPEEK_ASR_API_KEY_ENV",
			default: "ASR_API_KEY"
		).trimmingCharacters(in: .whitespacesAndNewlines)
		let explicitAPIKey = value(["asrApiKey", "asr_api_key"], "SPEEK_ASR_API_KEY", default: "")
		let apiKey = explicitAPIKey.isEmpty ? (values[apiKeyEnvironmentName] ?? "") : explicitAPIKey

		let requestedDeliveryMode = value(
			["deliveryMode", "delivery_mode"],
			"SPEEK_DELIVERY_MODE",
			default: "paste_and_send"
		).lowercased()
		let deliveryMode = ["paste_and_send", "paste_only", "clipboard_only"].contains(requestedDeliveryMode)
			? requestedDeliveryMode
			: "paste_and_send"

		let sampleRate = min(96_000, max(8_000, number(
			["sampleRate", "audioSampleRate", "sample_rate"],
			"SPEEK_AUDIO_SAMPLE_RATE",
			default: 16_000
		)))
		let timeout = min(600, max(1, number(["asrTimeout", "timeout"], "SPEEK_ASR_TIMEOUT", default: 600)))

		return AgentConfig(
			asrAPIURL: value(["asrApiUrl", "asr_api_url"], "SPEEK_ASR_API_URL", default: "http://127.0.0.1:8000/v1/audio/transcriptions"),
			asrModel: value(["asrModel", "asr_model"], "SPEEK_ASR_MODEL", default: "whisper-large-v3-turbo"),
			asrLanguage: value(["asrLanguage", "asr_language"], "SPEEK_ASR_LANGUAGE", default: ""),
			asrPrompt: value(["asrPrompt", "asr_prompt"], "SPEEK_ASR_PROMPT", default: ""),
			asrAPIKey: apiKey,
			asrTimeout: timeout,
			fakeTranscript: value(["fakeTranscript", "fake_transcript"], "SPEEK_FAKE_TRANSCRIPT", default: ""),
			audioInputDeviceName: value(["deviceName", "audioInputDeviceName", "device_name"], "SPEEK_AUDIO_INPUT_DEVICE_NAME", default: ""),
			audioInputDeviceIndex: value(["deviceIndex", "audioInputDeviceIndex", "device_index"], "SPEEK_AUDIO_INPUT_DEVICE_INDEX", default: ""),
			audioSampleRate: sampleRate,
			deliveryMode: deliveryMode,
			silenceGuard: boolean(["silenceGuard"], "SPEEK_SILENCE_GUARD", default: true),
			silenceMinimumRMSDB: number(["silenceMinimumRmsDb"], "SPEEK_SILENCE_MIN_RMS_DB", default: -75),
			silenceMinimumPeakDB: number(["silenceMinimumPeakDb"], "SPEEK_SILENCE_MIN_PEAK_DB", default: -65),
			readyOverlayEnabled: boolean(["readyOverlayEnabled", "hudEnabled"], "SPEEK_READY_OVERLAY_ENABLED", default: true),
			hudBinaryPath: value(
				["hudBinaryPath", "hudBin"],
				"SPEEK_HUD_BIN",
				default: URL(fileURLWithPath: home).appendingPathComponent(".config/karabiner/scripts/speek-hud").path
			),
			audioFeedbackEnabled: boolean(["audioFeedbackEnabled"], "SPEEK_AUDIO_FEEDBACK_ENABLED", default: true),
			feedbackSoundName: value(["feedbackSoundName"], "SPEEK_PRECONFIRM_SOUND_NAME", default: "Sosumi")
		)
	}
}

// MARK: - State files / HUD compatibility

private final class StateFiles: @unchecked Sendable {
	private let directory: URL
	private let fileQueue = DispatchQueue(label: "com.speek.coding.state-files", qos: .utility)

	init(directory: URL) {
		self.directory = directory
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		_ = chmod(directory.path, mode_t(S_IRWXU))
		if let staleRecordings = try? FileManager.default.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil
		) {
			for recording in staleRecordings
				where recording.lastPathComponent.hasPrefix("recording-") && recording.pathExtension == "wav"
			{
				try? FileManager.default.removeItem(at: recording)
			}
		}
		for staleName in ["session_id", "wav_path", "transcript", "transcript_ready"] {
			try? FileManager.default.removeItem(at: directory.appendingPathComponent(staleName))
		}
	}

	func write(_ name: String, _ value: String) {
		let target = directory.appendingPathComponent(name)
		fileQueue.async {
			try? Data(value.utf8).write(to: target, options: .atomic)
		}
	}

	func remove(_ names: [String]) {
		fileQueue.async { [directory] in
			for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
		}
	}

	func removeSynchronously(_ names: [String]) {
		fileQueue.sync { [directory] in
			for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
		}
	}

	func updateHUD(status: String, detail: String) {
		write("hud_status", status)
		write("hud_detail", detail)
		write("hud_updated_at", String(Date().timeIntervalSince1970))
	}

	func updateLevel(rmsDB: Double, peakDB: Double, waveform: [Double]) {
		let normalize: (Double) -> Double = { min(1, max(0, ($0 + 60) / 48)) }
		let level: JSONObject = [
			"rms_db": (rmsDB * 10).rounded() / 10,
			"peak_db": (peakDB * 10).rounded() / 10,
			"rms": (normalize(rmsDB) * 1000).rounded() / 1000,
			"peak": (normalize(peakDB) * 1000).rounded() / 1000,
		]
		if let data = try? JSONSerialization.data(withJSONObject: level), let text = String(data: data, encoding: .utf8) {
			write("audio_level", text)
		}
		write("audio_waveform", waveform.map { String(format: "%.3f", $0) }.joined(separator: ","))
		write("audio_level_updated_at", String(Date().timeIntervalSince1970))
	}
}

// MARK: - Native audio capture

private struct RecordingResult {
	let url: URL
	let bytes: Int
	let duration: TimeInterval
	let sampleRate: Double
	let rmsDB: Double
	let peakDB: Double
	let deviceName: String

	var json: JSONObject {
		[
			"wavPath": url.path,
			"bytes": bytes,
			"durationSeconds": duration,
			"sampleRate": sampleRate,
			"channels": 1,
			"bitsPerSample": 16,
			"rmsDb": rmsDB,
			"peakDb": peakDB,
			"audioInputDeviceName": deviceName,
		]
	}
}

private final class NativeRecorder: @unchecked Sendable {
	private let engine = AVAudioEngine()
	private let outputURL: URL
	private let targetSampleRate: Double
	private let stateFiles: StateFiles
	private let lock = NSLock()
	private var pcm = Data()
	private var inputSampleRate = 0.0
	private var resamplePosition = 0.0
	private var squaredSampleSum = 0.0
	private var absolutePeak = 0.0
	private var sampleCount = 0
	private var waveform = Array(repeating: 0.0, count: 18)
	private var lastLevelUpdate = 0.0
	private(set) var deviceName = "Default microphone"
	private var tapInstalled = false

	init(outputURL: URL, targetSampleRate: Double, stateFiles: StateFiles) {
		self.outputURL = outputURL
		self.targetSampleRate = targetSampleRate
		self.stateFiles = stateFiles
	}

	func start(deviceName requestedName: String, deviceIndex requestedIndex: String) throws {
		try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let inputNode = engine.inputNode
		deviceName = try configureInputDevice(
			requestedName: requestedName,
			requestedIndex: requestedIndex,
			inputNode: inputNode
		)

		let format = inputNode.outputFormat(forBus: 0)
		guard format.sampleRate > 0, format.channelCount > 0 else {
			throw failure("AUDIO_INPUT_UNAVAILABLE", "The selected microphone has no readable input format.")
		}
		inputSampleRate = format.sampleRate
		stateFiles.updateLevel(rmsDB: -120, peakDB: -120, waveform: waveform)

		inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
			self?.consume(buffer)
		}
		tapInstalled = true
		engine.prepare()
		do {
			try engine.start()
		} catch {
			inputNode.removeTap(onBus: 0)
			tapInstalled = false
			throw failure("AUDIO_ENGINE_START_FAILED", error.localizedDescription)
		}
	}

	func stop() throws -> RecordingResult {
		engine.stop()
		if tapInstalled {
			engine.inputNode.removeTap(onBus: 0)
			tapInstalled = false
		}

		lock.lock()
		let audio = pcm
		let count = sampleCount
		let squareSum = squaredSampleSum
		let peak = absolutePeak
		lock.unlock()

		var wav = Data()
		let payloadSize = UInt32(clamping: audio.count)
		wav.append(contentsOf: Data("RIFF".utf8))
		wav.appendLittleEndian(UInt32(clamping: 36 + Int(payloadSize)))
		wav.append(contentsOf: Data("WAVE".utf8))
		wav.append(contentsOf: Data("fmt ".utf8))
		wav.appendLittleEndian(UInt32(16))
		wav.appendLittleEndian(UInt16(1))
		wav.appendLittleEndian(UInt16(1))
		wav.appendLittleEndian(UInt32(targetSampleRate.rounded()))
		wav.appendLittleEndian(UInt32(targetSampleRate.rounded()) * 2)
		wav.appendLittleEndian(UInt16(2))
		wav.appendLittleEndian(UInt16(16))
		wav.append(contentsOf: Data("data".utf8))
		wav.appendLittleEndian(payloadSize)
		wav.append(audio)
		try wav.write(to: outputURL, options: .atomic)

		let rms = count > 0 ? sqrt(squareSum / Double(count)) : 0
		let rmsDB = Self.decibels(normalizedAmplitude: rms)
		let peakDB = Self.decibels(normalizedAmplitude: peak)
		stateFiles.updateLevel(rmsDB: rmsDB, peakDB: peakDB, waveform: waveform)
		return RecordingResult(
			url: outputURL,
			bytes: wav.count,
			duration: Double(count) / targetSampleRate,
			sampleRate: targetSampleRate,
			rmsDB: rmsDB,
			peakDB: peakDB,
			deviceName: deviceName
		)
	}

	private func consume(_ buffer: AVAudioPCMBuffer) {
		let frameCount = Int(buffer.frameLength)
		guard frameCount > 0 else { return }
		let channelCount = max(1, Int(buffer.format.channelCount))
		let ratio = inputSampleRate / targetSampleRate
		var encoded: [Int16] = []
		var chunkPeak = 0.0

		lock.lock()
		while resamplePosition < Double(frameCount) {
			let frame = min(frameCount - 1, max(0, Int(resamplePosition)))
			var mono = 0.0
			for channel in 0..<channelCount {
				mono += sample(buffer: buffer, frame: frame, channel: channel, channels: channelCount)
			}
			mono = min(1, max(-1, mono / Double(channelCount)))
			let intSample = Int16(max(Double(Int16.min), min(Double(Int16.max), (mono * 32_767).rounded())))
			encoded.append(intSample.littleEndian)
			let absolute = abs(mono)
			chunkPeak = max(chunkPeak, absolute)
			absolutePeak = max(absolutePeak, absolute)
			squaredSampleSum += mono * mono
			sampleCount += 1
			resamplePosition += ratio
		}
		resamplePosition -= Double(frameCount)
		encoded.withUnsafeBytes { pcm.append(contentsOf: $0) }

		let now = ProcessInfo.processInfo.systemUptime
		var levelUpdate: (Double, Double, [Double])?
		if now - lastLevelUpdate >= 0.12 {
			lastLevelUpdate = now
			let rms = sampleCount > 0 ? sqrt(squaredSampleSum / Double(sampleCount)) : 0
			let rmsDB = Self.decibels(normalizedAmplitude: rms)
			let peakDB = Self.decibels(normalizedAmplitude: chunkPeak)
			let normalizedPeak = min(1, max(0, (peakDB + 60) / 48))
			waveform.append(normalizedPeak)
			waveform = Array(waveform.suffix(18))
			levelUpdate = (rmsDB, peakDB, waveform)
		}
		lock.unlock()

		if let update = levelUpdate {
			stateFiles.updateLevel(rmsDB: update.0, peakDB: update.1, waveform: update.2)
		}
	}

	private func sample(buffer: AVAudioPCMBuffer, frame: Int, channel: Int, channels: Int) -> Double {
		let interleaved = buffer.format.isInterleaved
		let index = interleaved ? frame * channels + channel : frame
		let pointerChannel = interleaved ? 0 : channel
		switch buffer.format.commonFormat {
		case .pcmFormatFloat32:
			return Double(buffer.floatChannelData?[pointerChannel][index] ?? 0)
		case .pcmFormatFloat64:
			let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
			guard buffers.indices.contains(pointerChannel), let data = buffers[pointerChannel].mData else { return 0 }
			return data.assumingMemoryBound(to: Double.self)[index]
		case .pcmFormatInt16:
			return Double(buffer.int16ChannelData?[pointerChannel][index] ?? 0) / 32_768
		case .pcmFormatInt32:
			return Double(buffer.int32ChannelData?[pointerChannel][index] ?? 0) / 2_147_483_648
		default:
			return 0
		}
	}

	private static func decibels(normalizedAmplitude: Double) -> Double {
		guard normalizedAmplitude > 0 else { return -120 }
		return max(-120, 20 * log10(normalizedAmplitude))
	}

	private func configureInputDevice(
		requestedName: String,
		requestedIndex: String,
		inputNode: AVAudioInputNode
	) throws -> String {
		let devices = audioInputDevices()
		let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
		let selected: AVCaptureDevice?
		if !trimmedName.isEmpty, !["default", "default microphone"].contains(trimmedName.lowercased()) {
			selected = devices.first { $0.localizedName.caseInsensitiveCompare(trimmedName) == .orderedSame }
				?? devices.first { $0.localizedName.localizedCaseInsensitiveContains(trimmedName) }
			guard selected != nil else {
				let available = devices.map(\.localizedName).joined(separator: ", ")
				throw failure(
					"AUDIO_DEVICE_NOT_FOUND",
					"Audio input \"\(trimmedName)\" was not found. Available inputs: \(available.isEmpty ? "none" : available)."
				)
			}
		} else if let index = Int(requestedIndex), devices.indices.contains(index) {
			selected = devices[index]
		} else {
			selected = nil
		}

		guard let device = selected else {
			return AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default microphone"
		}
		guard let audioUnit = inputNode.audioUnit else {
			throw failure("AUDIO_UNIT_UNAVAILABLE", "The audio input unit is unavailable.")
		}

		var uid: CFString = device.uniqueID as CFString
		var deviceID = AudioObjectID(kAudioObjectUnknown)
		var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
		var address = AudioObjectPropertyAddress(
			mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
			mScope: kAudioObjectPropertyScopeGlobal,
			mElement: kAudioObjectPropertyElementMain
		)
		let translationStatus = withUnsafePointer(to: &uid) { uidPointer in
			AudioObjectGetPropertyData(
				AudioObjectID(kAudioObjectSystemObject),
				&address,
				UInt32(MemoryLayout<CFString>.size),
				UnsafeRawPointer(uidPointer),
				&outputSize,
				&deviceID
			)
		}
		guard translationStatus == noErr, deviceID != kAudioObjectUnknown else {
			throw failure("AUDIO_DEVICE_RESOLUTION_FAILED", "Could not resolve audio input \"\(device.localizedName)\".")
		}

		var mutableDeviceID = deviceID
		let selectionStatus = AudioUnitSetProperty(
			audioUnit,
			kAudioOutputUnitProperty_CurrentDevice,
			kAudioUnitScope_Global,
			0,
			&mutableDeviceID,
			UInt32(MemoryLayout<AudioDeviceID>.size)
		)
		guard selectionStatus == noErr else {
			throw failure(
				"AUDIO_DEVICE_SELECTION_FAILED",
				"Could not select audio input \"\(device.localizedName)\" (CoreAudio status \(selectionStatus))."
			)
		}
		return device.localizedName
	}
}

// MARK: - ASR and delivery

private enum NativeTranscriber {
	@discardableResult
	static func transcribe(
		wavURL: URL,
		config: AgentConfig,
		completion: @escaping (Result<String, Error>) -> Void
	) -> URLSessionDataTask? {
		if !config.fakeTranscript.isEmpty {
			DispatchQueue.global(qos: .userInitiated).async { completion(.success(config.fakeTranscript)) }
			return nil
		}
		guard let endpoint = URL(string: config.asrAPIURL), !config.asrAPIURL.isEmpty else {
			completion(.failure(failure("INVALID_ASR_URL", "SPEEK_ASR_API_URL is missing or invalid.")))
			return nil
		}
		let scheme = endpoint.scheme?.lowercased()
		guard scheme == "https" || (scheme == "http" && isLoopbackHost(endpoint.host)) else {
			completion(.failure(failure(
				"INSECURE_ASR_URL",
				"Remote ASR endpoints must use HTTPS; plain HTTP is allowed only on the local loopback interface."
			)))
			return nil
		}
		guard endpoint.user == nil, endpoint.password == nil else {
			completion(.failure(failure(
				"INVALID_ASR_URL",
				"Do not embed credentials in SPEEK_ASR_API_URL; configure an API key separately."
			)))
			return nil
		}
		guard !config.asrModel.isEmpty else {
			completion(.failure(failure("ASR_MODEL_MISSING", "SPEEK_ASR_MODEL is required.")))
			return nil
		}

		do {
			let boundary = "speek-\(UUID().uuidString)"
			var body = Data()
			func appendField(_ name: String, _ value: String) {
				body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
				body.append(contentsOf: Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
				body.append(contentsOf: Data(value.utf8))
				body.append(contentsOf: Data("\r\n".utf8))
			}
			appendField("model", config.asrModel)
			if !config.asrLanguage.isEmpty { appendField("language", config.asrLanguage) }
			if !config.asrPrompt.isEmpty { appendField("prompt", config.asrPrompt) }
			body.append(contentsOf: Data("--\(boundary)\r\n".utf8))
			body.append(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(wavURL.lastPathComponent)\"\r\n".utf8))
			body.append(contentsOf: Data("Content-Type: audio/wav\r\n\r\n".utf8))
			body.append(try Data(contentsOf: wavURL))
			body.append(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))

			var request = URLRequest(url: endpoint, timeoutInterval: config.asrTimeout)
			request.httpMethod = "POST"
			request.httpBody = body
			request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
			request.setValue("application/json", forHTTPHeaderField: "Accept")
			if !config.asrAPIKey.isEmpty {
				request.setValue("Bearer \(config.asrAPIKey)", forHTTPHeaderField: "Authorization")
			}

			let task = URLSession.shared.dataTask(with: request) { data, response, error in
				if let error { completion(.failure(failure("ASR_REQUEST_FAILED", error.localizedDescription))); return }
				guard let http = response as? HTTPURLResponse else {
					completion(.failure(failure("ASR_INVALID_RESPONSE", "The ASR endpoint returned no HTTP response.")))
					return
				}
				let payload = data ?? Data()
				guard (200..<300).contains(http.statusCode) else {
					let detail = String(data: payload.prefix(1_000), encoding: .utf8) ?? ""
					completion(.failure(failure("ASR_HTTP_ERROR", "ASR HTTP \(http.statusCode): \(detail)")))
					return
				}
				do { completion(.success(try parseTranscript(payload))) }
				catch { completion(.failure(error)) }
			}
			task.resume()
			return task
		} catch {
			completion(.failure(failure("ASR_REQUEST_BUILD_FAILED", error.localizedDescription)))
			return nil
		}
	}

	private static func parseTranscript(_ data: Data) throws -> String {
		if let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject {
			if let text = object["text"] as? String { return clean(text) }
			if let text = object["transcript"] as? String { return clean(text) }
			if let nested = object["data"] as? JSONObject, let text = nested["text"] as? String { return clean(text) }
			throw failure("ASR_TEXT_MISSING", "The ASR JSON response does not contain text.")
		}
		guard let text = String(data: data, encoding: .utf8) else {
			throw failure("ASR_INVALID_RESPONSE", "The ASR response is neither JSON nor UTF-8 text.")
		}
		return clean(text)
	}

	private static func clean(_ text: String) -> String {
		text.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

private enum NativeDelivery {
	static func deliver(text: String, mode: String, targetProcessIdentifier: pid_t?) throws -> JSONObject {
		guard !text.isEmpty else { throw failure("EMPTY_TRANSCRIPT", "The transcript is empty.") }
		var clipboardWritten = false
		let clipboardOperation = {
			let pasteboard = NSPasteboard.general
			pasteboard.clearContents()
			clipboardWritten = pasteboard.writeObjects([text as NSString])
		}
		if Thread.isMainThread { clipboardOperation() } else { DispatchQueue.main.sync(execute: clipboardOperation) }
		guard clipboardWritten else { throw failure("CLIPBOARD_WRITE_FAILED", "Could not write the transcript to the clipboard.") }
		if mode == "clipboard_only" {
			return ["mode": mode, "clipboard": true, "pasted": false, "sent": false]
		}
		guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
			throw failure(
				"ACCESSIBILITY_PERMISSION_REQUIRED",
				"Allow SpeekCoding in System Settings > Privacy & Security > Accessibility."
			)
		}
		guard let targetProcessIdentifier,
			let targetApplication = NSRunningApplication(processIdentifier: targetProcessIdentifier),
			!targetApplication.isTerminated
		else {
			throw failure("TARGET_APP_UNAVAILABLE", "The app that was active when recording started is no longer available.")
		}
		try postKey(virtualKey: 0x09, flags: .maskCommand, targetProcessIdentifier: targetProcessIdentifier) // Command-V
		Thread.sleep(forTimeInterval: 0.12)
		if mode == "paste_and_send" {
			Thread.sleep(forTimeInterval: 0.48)
			try postKey(virtualKey: 0x24, flags: [], targetProcessIdentifier: targetProcessIdentifier) // Return
		}
		return [
			"mode": mode,
			"clipboard": true,
			"pasted": true,
			"sent": mode == "paste_and_send",
		]
	}

	private static func postKey(
		virtualKey: CGKeyCode,
		flags: CGEventFlags,
		targetProcessIdentifier: pid_t
	) throws {
		guard let source = CGEventSource(stateID: .hidSystemState),
			let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
			let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
		else { throw failure("EVENT_CREATION_FAILED", "Could not create a keyboard event.") }
		down.flags = flags
		up.flags = flags
		down.postToPid(targetProcessIdentifier)
		up.postToPid(targetProcessIdentifier)
	}
}

// MARK: - Permission-bearing state machine

private enum AgentState: String {
	case idle
	case starting
	case recording
	case testing
	case transcribing
}

private final class SpeekAgent: @unchecked Sendable {
	static let shared = SpeekAgent()

	private let queue = DispatchQueue(label: "com.speek.coding.agent", qos: .userInitiated)
	private let files = StateFiles(directory: stateDirectoryURL)
	private var state: AgentState = .idle
	private var sessionID: String?
	private var wavURL: URL?
	private var recorder: NativeRecorder?
	private var asrTask: URLSessionDataTask?
	private var pendingStartCompletion: AgentCompletion?
	private var pendingTestCompletion: AgentCompletion?
	private var hudProcess: Process?
	private var targetProcessIdentifier: pid_t?
	private var hudRequestTimer: DispatchSourceTimer?

	func handle(_ request: JSONObject, completion: @escaping AgentCompletion) {
		queue.async { [self] in
			let rawCommand = stringValue(request["command"] ?? request["action"] ?? request["cmd"]) ?? ""
			let command = normalizeCommand(rawCommand)
			guard !command.isEmpty else {
				completion(errorResponse(command: "unknown", error: failure("COMMAND_MISSING", "A command is required."), state: state.rawValue))
				return
			}
			switch command {
			case "ping": completion(success(command: command, data: pingData()))
			case "status": completion(success(command: command, data: statusData()))
			case "permissions": handlePermissions(request, command: command, completion: completion)
			case "save": handleSave(request, command: command, completion: completion)
			case "watch": handleWatch(request, command: command, completion: completion)
			case "toggle": handleToggle(request, command: command, completion: completion)
			case "cancel": handleCancel(command: command, completion: completion)
			case "test-record": handleTestRecord(request, command: command, completion: completion)
			case "shutdown":
				completion(success(command: command, data: ["shuttingDown": true]))
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
			default:
				completion(errorResponse(command: command, error: failure("UNKNOWN_COMMAND", "Unknown command: \(rawCommand)"), state: state.rawValue))
			}
		}
	}

	func stopForTermination() {
		queue.sync {
			hudRequestTimer?.cancel()
			hudRequestTimer = nil
			if let process = hudProcess, process.isRunning { process.terminate() }
			hudProcess = nil
			asrTask?.cancel()
			_ = try? recorder?.stop()
			recorder = nil
			if let wavURL { try? FileManager.default.removeItem(at: wavURL) }
			files.removeSynchronously(["session_id", "wav_path", "transcript", "transcript_ready", "hud_status", "hud_cancel_request"])
			sessionID = nil
			wavURL = nil
			targetProcessIdentifier = nil
		}
	}

	private func normalizeCommand(_ raw: String) -> String {
		switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "start", "start-recording", "record", "save": return "save"
		case "stop", "stop-recording", "transcribe", "watch": return "watch"
		case "test_record", "testrecord", "test-record": return "test-record"
		case "permission", "permissions": return "permissions"
		default: return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		}
	}

	private func pingData() -> JSONObject {
		[
			"appName": agentName,
			"bundleIdentifier": Bundle.main.bundleIdentifier ?? agentBundleIdentifier,
			"protocolVersion": protocolVersion,
			"pid": ProcessInfo.processInfo.processIdentifier,
			"socketPath": socketURL.path,
			"state": state.rawValue,
		]
	}

	private func statusData() -> JSONObject {
		var result = pingData()
		result["sessionId"] = sessionID ?? NSNull()
		result["wavPath"] = wavURL?.path ?? NSNull()
		result["recording"] = state == .recording || state == .testing
		result["transcribing"] = state == .transcribing
		result["targetProcessIdentifier"] = targetProcessIdentifier ?? 0
		return result
	}

	private func success(command: String, data: JSONObject = [:]) -> JSONObject {
		var response: JSONObject = ["ok": true, "command": command, "state": state.rawValue]
		for (key, value) in data { response[key] = value }
		return response
	}

	private func handlePermissions(_ request: JSONObject, command: String, completion: @escaping AgentCompletion) {
		let prompt = boolValue(request["prompt"]) ?? false
		if prompt {
			let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
			_ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
			if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
		}
		let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
		if prompt, microphone == .notDetermined {
			AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
				self?.queue.async {
					guard let self else { return }
					completion(self.success(command: command, data: self.permissionData()))
				}
			}
		} else {
			completion(success(command: command, data: permissionData()))
		}
	}

	private func permissionData() -> JSONObject {
		let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
		let microphoneStatus: String
		switch microphone {
		case .authorized: microphoneStatus = "granted"
		case .denied: microphoneStatus = "denied"
		case .restricted: microphoneStatus = "restricted"
		case .notDetermined: microphoneStatus = "not_determined"
		@unknown default: microphoneStatus = "unknown"
		}
		let accessibility = AXIsProcessTrusted()
		let postEvent = CGPreflightPostEventAccess()
		let allGranted = microphone == .authorized && accessibility && postEvent
		return [
			"permissionStatus": allGranted ? "ok" : "action_required",
			"permissions": [
				"microphone": microphoneStatus,
				"accessibility": accessibility ? "granted" : "denied",
				"postEvent": postEvent ? "granted" : "denied",
			],
			"items": [
				["key": "microphone", "label": "Microphone", "status": microphoneStatus, "source": "avfoundation"],
				["key": "accessibility", "label": "Accessibility", "status": accessibility ? "granted" : "denied", "source": "ax_api"],
				["key": "postEvent", "label": "Event posting", "status": postEvent ? "granted" : "denied", "source": "coregraphics_api"],
			],
		]
	}

	private func handleToggle(_ request: JSONObject, command: String, completion: @escaping AgentCompletion) {
		switch state {
		case .idle: handleSave(request, command: command, completion: completion)
		case .recording: handleWatch(request, command: command, completion: completion)
		case .transcribing: handleCancel(command: command, completion: completion)
		default:
			completion(errorResponse(command: command, error: failure("AGENT_BUSY", "SpeekCoding is currently \(state.rawValue)."), state: state.rawValue))
		}
	}

	private func handleSave(_ request: JSONObject, command: String, completion: @escaping AgentCompletion) {
		guard state == .idle else {
			completion(errorResponse(command: command, error: failure("AGENT_BUSY", "SpeekCoding is currently \(state.rawValue)."), state: state.rawValue))
			return
		}
		let config = AgentConfig.load(overrides: request)
		let identifier = UUID().uuidString.lowercased()
		let output = stateDirectoryURL.appendingPathComponent("recording-\(identifier).wav")
		state = .starting
		sessionID = identifier
		wavURL = output
		targetProcessIdentifier = captureFrontmostProcessIdentifier()
		if targetProcessIdentifier == nil, config.deliveryMode != "clipboard_only" {
			state = .idle
			clearSession()
			completion(errorResponse(
				command: command,
				error: failure("TARGET_APP_UNAVAILABLE", "No frontmost target app is available for text delivery."),
				state: state.rawValue
			))
			return
		}
		pendingStartCompletion = completion
		startWhenMicrophoneAuthorized(
			identifier: identifier,
			config: config,
			output: output,
			command: command,
			testDuration: nil
		)
	}

	private func handleTestRecord(_ request: JSONObject, command: String, completion: @escaping AgentCompletion) {
		guard state == .idle else {
			completion(errorResponse(command: command, error: failure("AGENT_BUSY", "SpeekCoding is currently \(state.rawValue)."), state: state.rawValue))
			return
		}
		let duration = doubleValue(request["durationSeconds"] ?? request["duration"] ?? request["seconds"]) ?? 2
		guard duration > 0, duration <= 300 else {
			completion(errorResponse(command: command, error: failure("INVALID_DURATION", "Test duration must be greater than 0 and at most 300 seconds."), state: state.rawValue))
			return
		}
		let config = AgentConfig.load(overrides: request)
		let identifier = "test-\(UUID().uuidString.lowercased())"
		let requestedPath = stringValue(request["wavPath"] ?? request["wav_path"])
		let output = requestedPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
			?? stateDirectoryURL.appendingPathComponent("\(identifier).wav")
		state = .starting
		sessionID = identifier
		wavURL = output
		pendingStartCompletion = completion
		startWhenMicrophoneAuthorized(
			identifier: identifier,
			config: config,
			output: output,
			command: command,
			testDuration: duration
		)
	}

	private func startWhenMicrophoneAuthorized(
		identifier: String,
		config: AgentConfig,
		output: URL,
		command: String,
		testDuration: TimeInterval?
	) {
		func continueStart(_ granted: Bool) {
			queue.async { [self] in
				guard state == .starting, sessionID == identifier else { return }
				guard granted else {
					state = .idle
					let callback = pendingStartCompletion
					pendingStartCompletion = nil
					clearSession()
					callback?(errorResponse(
						command: command,
						error: failure("MICROPHONE_PERMISSION_REQUIRED", "Allow SpeekCoding to use the microphone in System Settings > Privacy & Security > Microphone."),
						state: state.rawValue
					))
					return
				}
				do {
					let newRecorder = NativeRecorder(outputURL: output, targetSampleRate: config.audioSampleRate, stateFiles: files)
					try newRecorder.start(deviceName: config.audioInputDeviceName, deviceIndex: config.audioInputDeviceIndex)
					recorder = newRecorder
					files.write("session_id", identifier)
					files.write("wav_path", output.path)
					files.write("hud_started_at", String(Date().timeIntervalSince1970))
					files.updateHUD(status: "recording", detail: newRecorder.deviceName)
					launchHUDIfNeeded(config)
					if let duration = testDuration {
						state = .testing
						pendingTestCompletion = pendingStartCompletion
						pendingStartCompletion = nil
						queue.asyncAfter(deadline: .now() + duration) { [self] in finishTestRecording(identifier: identifier, duration: duration, command: command) }
					} else {
						state = .recording
						queue.asyncAfter(deadline: .now() + 300) { [weak self] in
							guard let self, self.state == .recording, self.sessionID == identifier else { return }
							self.handleCancel(command: "cancel") { _ in }
							self.files.updateHUD(status: "timeout", detail: "Recording timed out")
						}
						let callback = pendingStartCompletion
						pendingStartCompletion = nil
						callback?(success(command: command, data: [
							"sessionId": identifier,
							"wavPath": output.path,
							"audioInputDeviceName": newRecorder.deviceName,
							"sampleRate": config.audioSampleRate,
						]))
					}
				} catch {
					state = .idle
					files.updateHUD(status: "error", detail: error.localizedDescription)
					let callback = pendingStartCompletion
					pendingStartCompletion = nil
					clearSession()
					callback?(errorResponse(command: command, error: error, state: state.rawValue))
				}
			}
		}

		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized: continueStart(true)
		case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: continueStart)
		default: continueStart(false)
		}
	}

	private func finishTestRecording(identifier: String, duration: TimeInterval, command: String) {
		guard state == .testing, sessionID == identifier else { return }
		let callback = pendingTestCompletion
		pendingTestCompletion = nil
		do {
			guard let recorder else { throw failure("RECORDER_MISSING", "The native recorder is unavailable.") }
			let result = try recorder.stop()
			self.recorder = nil
			state = .idle
			files.updateHUD(status: "sent", detail: "Test recording saved")
			var data = result.json
			data["requestedDurationSeconds"] = duration
			data["sessionId"] = identifier
			clearSession(preserveRecording: true)
			callback?(success(command: command, data: data))
		} catch {
			self.recorder = nil
			state = .idle
			files.updateHUD(status: "error", detail: error.localizedDescription)
			clearSession()
			callback?(errorResponse(command: command, error: error, state: state.rawValue))
		}
	}

	private func handleWatch(_ request: JSONObject, command: String, completion: @escaping AgentCompletion) {
		guard state == .recording, let identifier = sessionID, let recorder else {
			completion(errorResponse(command: command, error: failure("NOT_RECORDING", "SpeekCoding is not recording."), state: state.rawValue))
			return
		}
		let config = AgentConfig.load(overrides: request)
		state = .transcribing
		files.updateHUD(status: "transcribing", detail: "Press Fn to cancel")
		do {
			let recording = try recorder.stop()
			self.recorder = nil
			if config.silenceGuard,
				recording.rmsDB <= config.silenceMinimumRMSDB,
				recording.peakDB <= config.silenceMinimumPeakDB
			{
				state = .idle
				files.updateHUD(status: "nospeech", detail: "Mic level is flat")
				var data = recording.json
				data["sessionId"] = identifier
				data["transcript"] = ""
				data["reason"] = "no_speech"
				clearSession()
				completion(success(command: command, data: data))
				return
			}

			asrTask = NativeTranscriber.transcribe(wavURL: recording.url, config: config) { [weak self] result in
				self?.queue.async {
					guard let self else { return }
					guard self.state == .transcribing, self.sessionID == identifier else {
						completion(errorResponse(command: command, error: failure("CANCELED", "The transcription was canceled."), state: self.state.rawValue))
						return
					}
					self.asrTask = nil
					switch result {
					case .failure(let error):
						self.state = .idle
						self.files.updateHUD(status: "error", detail: "Transcription failed")
						self.clearSession()
						completion(errorResponse(command: command, error: error, state: self.state.rawValue))
					case .success(let transcript):
						self.finishTranscription(
							transcript: transcript,
							recording: recording,
							config: config,
							identifier: identifier,
							command: command,
							completion: completion
						)
					}
				}
			}
			pollModelPhase(config: config, identifier: identifier)
		} catch {
			self.recorder = nil
			state = .idle
			files.updateHUD(status: "error", detail: error.localizedDescription)
			clearSession()
			completion(errorResponse(command: command, error: error, state: state.rawValue))
		}
	}

	private func pollModelPhase(config: AgentConfig, identifier: String) {
		guard config.fakeTranscript.isEmpty, let endpoint = URL(string: config.asrAPIURL),
			isLoopbackHost(endpoint.host), var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
		else { return }
		components.path = "/health"
		components.query = nil
		guard let healthURL = components.url else { return }
		URLSession.shared.dataTask(with: healthURL) { [weak self] data, _, _ in
			let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSONObject }
			let phase = object?["model_phase"] as? String
			self?.queue.async {
				guard let self, self.state == .transcribing, self.sessionID == identifier else { return }
				switch phase {
				case "downloading": self.files.updateHUD(status: "downloading", detail: "Press Fn to cancel")
				case "loading": self.files.updateHUD(status: "loading", detail: "Press Fn to cancel")
				default: self.files.updateHUD(status: "transcribing", detail: "Press Fn to cancel")
				}
				self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
					guard let self, self.state == .transcribing, self.sessionID == identifier else { return }
					self.pollModelPhase(config: config, identifier: identifier)
				}
			}
		}.resume()
	}

	private func finishTranscription(
		transcript: String,
		recording: RecordingResult,
		config: AgentConfig,
		identifier: String,
		command: String,
		completion: @escaping AgentCompletion
	) {
		guard !transcript.isEmpty else {
			state = .idle
			files.updateHUD(status: "nospeech", detail: "No speech recognized")
			var data = recording.json
			data["sessionId"] = identifier
			data["transcript"] = ""
			data["reason"] = "empty_transcript"
			clearSession()
			completion(success(command: command, data: data))
			return
		}
		files.write("transcript", transcript)
		do {
			let delivery = try NativeDelivery.deliver(
				text: transcript,
				mode: config.deliveryMode,
				targetProcessIdentifier: targetProcessIdentifier
			)
			state = .idle
			switch config.deliveryMode {
			case "clipboard_only": files.updateHUD(status: "sent", detail: "Copied to clipboard")
			case "paste_only": files.updateHUD(status: "sent", detail: "Text pasted")
			default: files.updateHUD(status: "sent", detail: "Prompt submitted")
			}
			playFeedbackIfNeeded(config)
			var data = recording.json
			data["sessionId"] = identifier
			data["transcript"] = transcript
			data["delivery"] = delivery
			clearSession()
			completion(success(command: command, data: data))
		} catch {
			state = .idle
			if (error as? AgentFailure)?.code == "ACCESSIBILITY_PERMISSION_REQUIRED" {
				files.updateHUD(status: "permission", detail: "Allow Accessibility")
			} else {
				files.updateHUD(status: "error", detail: "Delivery failed")
			}
			clearSession()
			var response = errorResponse(command: command, error: error, state: state.rawValue)
			response["transcript"] = transcript
			response["recordingRetained"] = false
			completion(response)
		}
	}

	private func handleCancel(command: String, completion: @escaping AgentCompletion) {
		let previousState = state
		let previousSession = sessionID
		asrTask?.cancel()
		asrTask = nil
		_ = try? recorder?.stop()
		recorder = nil
		state = .idle
		files.updateHUD(status: "canceled", detail: "Canceled")

		if let pending = pendingStartCompletion {
			pendingStartCompletion = nil
			pending(errorResponse(command: "save", error: failure("CANCELED", "Recording start was canceled."), state: state.rawValue))
		}
		if let pending = pendingTestCompletion {
			pendingTestCompletion = nil
			pending(errorResponse(command: "test-record", error: failure("CANCELED", "Test recording was canceled."), state: state.rawValue))
		}
		clearSession()
		completion(success(command: command, data: [
			"canceled": previousState != .idle,
			"previousState": previousState.rawValue,
			"sessionId": previousSession ?? NSNull(),
		]))
	}

	private func clearSession(preserveRecording: Bool = false) {
		let recordingURL = wavURL
		sessionID = nil
		wavURL = nil
		targetProcessIdentifier = nil
		if !preserveRecording, let recordingURL {
			try? FileManager.default.removeItem(at: recordingURL)
		}
		files.remove(["session_id", "wav_path", "pending_confirm", "transcript", "transcript_ready"])
	}

	private func captureFrontmostProcessIdentifier() -> pid_t? {
		var processIdentifier: pid_t?
		DispatchQueue.main.sync {
			guard let application = NSWorkspace.shared.frontmostApplication,
				application.processIdentifier != ProcessInfo.processInfo.processIdentifier
			else { return }
			processIdentifier = application.processIdentifier
		}
		return processIdentifier
	}

	private func launchHUDIfNeeded(_ config: AgentConfig) {
		guard config.readyOverlayEnabled, FileManager.default.isExecutableFile(atPath: config.hudBinaryPath) else { return }
		if let process = hudProcess, process.isRunning { return }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: config.hudBinaryPath)
		process.arguments = ["--state-dir", stateDirectoryURL.path, "--parent-pid", String(getpid())]
		files.removeSynchronously(["hud_cancel_request"])
		if hudRequestTimer == nil {
			let timer = DispatchSource.makeTimerSource(queue: queue)
			timer.schedule(deadline: .now(), repeating: .milliseconds(200))
			timer.setEventHandler { [weak self] in
				guard let self else { return }
				let requestURL = stateDirectoryURL.appendingPathComponent("hud_cancel_request")
				guard let requestedSession = try? String(contentsOf: requestURL, encoding: .utf8) else { return }
				try? FileManager.default.removeItem(at: requestURL)
				guard requestedSession == self.sessionID, self.state != .idle else { return }
				self.handleCancel(command: "cancel") { _ in }
			}
			hudRequestTimer = timer
			timer.resume()
		}
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
			hudProcess = process
		} catch {
			// HUD failure must never stop recording.
		}
	}

	private func playFeedbackIfNeeded(_ config: AgentConfig) {
		guard config.audioFeedbackEnabled, !config.feedbackSoundName.isEmpty else { return }
		DispatchQueue.main.async {
			NSSound(named: NSSound.Name(config.feedbackSoundName))?.play()
		}
	}
}

// MARK: - Local Unix socket

private final class UnixSocketServer: @unchecked Sendable {
	private var descriptor: Int32 = -1
	private let listenerQueue = DispatchQueue(label: "com.speek.coding.socket-listener", qos: .userInitiated)
	private let clientsQueue = DispatchQueue(label: "com.speek.coding.socket-clients", qos: .userInitiated, attributes: .concurrent)
	private var stopped = false
	private var ipcToken = ""

	func start() throws {
		ipcToken = readIPCToken()
		guard ipcToken.count == 64, ipcToken.allSatisfy({ $0.isHexDigit }) else {
			throw failure("IPC_CREDENTIAL_MISSING", "SpeekCoding's private IPC credential is missing or invalid.")
		}
		try Self.prepareStateDirectory()
		var socketMetadata = stat()
		if lstat(socketURL.path, &socketMetadata) == 0 {
			guard socketMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
				throw failure(
					"UNSAFE_SOCKET_PATH",
					"Refusing to replace \(socketURL.path) because it is not a Unix socket."
				)
			}
			if Self.canConnect(path: socketURL.path) {
				throw failure("AGENT_ALREADY_RUNNING", "Another SpeekCoding agent is already listening at \(socketURL.path).")
			}
			guard unlink(socketURL.path) == 0 else {
				throw failure("SOCKET_REMOVE_FAILED", String(cString: strerror(errno)))
			}
		} else if errno != ENOENT {
			throw failure("SOCKET_INSPECTION_FAILED", String(cString: strerror(errno)))
		}

		let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw failure("SOCKET_CREATE_FAILED", String(cString: strerror(errno))) }
		descriptor = fd
		var one: Int32 = 1
		_ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

		var address = try Self.address(path: socketURL.path)
		let bindResult = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard bindResult == 0 else {
			let detail = String(cString: strerror(errno))
			Darwin.close(fd)
			descriptor = -1
			throw failure("SOCKET_BIND_FAILED", detail)
		}
		_ = chmod(socketURL.path, mode_t(S_IRUSR | S_IWUSR))
		guard Darwin.listen(fd, 32) == 0 else {
			let detail = String(cString: strerror(errno))
			Darwin.close(fd)
			descriptor = -1
			_ = unlink(socketURL.path)
			throw failure("SOCKET_LISTEN_FAILED", detail)
		}

		listenerQueue.async { [weak self] in self?.acceptLoop() }
	}

	func stop() {
		stopped = true
		if descriptor >= 0 {
			Darwin.shutdown(descriptor, SHUT_RDWR)
			Darwin.close(descriptor)
			descriptor = -1
		}
		_ = unlink(socketURL.path)
	}

	private func acceptLoop() {
		while !stopped, descriptor >= 0 {
			let client = Darwin.accept(descriptor, nil, nil)
			if client < 0 {
				if errno == EINTR { continue }
				if stopped { return }
				continue
			}
			var peerUserID = uid_t.max
			var peerGroupID = gid_t.max
			guard getpeereid(client, &peerUserID, &peerGroupID) == 0, peerUserID == geteuid() else {
				Darwin.close(client)
				continue
			}
			var one: Int32 = 1
			_ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
			clientsQueue.async { [weak self] in self?.serve(client) }
		}
	}

	private func serve(_ client: Int32) {
		defer { Darwin.close(client) }
		var pending = Data()
		var buffer = [UInt8](repeating: 0, count: 8_192)
		while !stopped {
			let count = Darwin.read(client, &buffer, buffer.count)
			if count < 0 {
				if errno == EINTR { continue }
				return
			}
			if count == 0 {
				if !pending.isEmpty { processLine(pending, client: client) }
				return
			}
			pending.append(buffer, count: count)
			if pending.count > 1_048_576 {
				write(response: errorResponse(command: "unknown", error: failure("REQUEST_TOO_LARGE", "IPC requests are limited to 1 MiB."), state: "unknown"), to: client)
				return
			}
			while let newline = pending.firstIndex(of: 0x0A) {
				let line = pending[..<newline]
				pending.removeSubrange(...newline)
				if !line.isEmpty { processLine(Data(line), client: client) }
			}
		}
	}

	private func processLine(_ line: Data, client: Int32) {
		var request: JSONObject
		do {
			guard let object = try JSONSerialization.jsonObject(with: line) as? JSONObject else {
				throw failure("INVALID_REQUEST", "Each IPC line must be a JSON object.")
			}
			request = object
		} catch {
			write(response: errorResponse(command: "unknown", error: error, state: "unknown"), to: client)
			return
		}
		guard let suppliedToken = stringValue(request.removeValue(forKey: "token")),
			secureEquals(suppliedToken, ipcToken)
		else {
			write(response: errorResponse(command: "unknown", error: failure("IPC_UNAUTHORIZED", "The IPC credential is invalid."), state: "unknown"), to: client)
			return
		}

		let semaphore = DispatchSemaphore(value: 0)
		var response: JSONObject?
		SpeekAgent.shared.handle(request) {
			response = $0
			semaphore.signal()
		}
		let result = semaphore.wait(timeout: .now() + 660)
		if result == .timedOut {
			write(response: errorResponse(command: stringValue(request["command"]) ?? "unknown", error: failure("IPC_TIMEOUT", "The agent command timed out."), state: "unknown"), to: client)
		} else if let response {
			write(response: response, to: client)
		}
	}

	private func write(response: JSONObject, to client: Int32) {
		guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
		data.append(0x0A)
		data.withUnsafeBytes { rawBuffer in
			guard var pointer = rawBuffer.baseAddress else { return }
			var remaining = rawBuffer.count
			while remaining > 0 {
				let written = Darwin.write(client, pointer, remaining)
				if written < 0 {
					if errno == EINTR { continue }
					return
				}
				remaining -= written
				pointer = pointer.advanced(by: written)
			}
		}
	}

	private static func address(path: String) throws -> sockaddr_un {
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		let bytes = Array(path.utf8CString)
		let capacity = MemoryLayout.size(ofValue: address.sun_path)
		guard bytes.count <= capacity else { throw failure("SOCKET_PATH_TOO_LONG", "Unix socket path is too long: \(path)") }
		withUnsafeMutableBytes(of: &address.sun_path) { destination in
			destination.initializeMemory(as: UInt8.self, repeating: 0)
			bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
		}
		return address
	}

	private static func prepareStateDirectory() throws {
		var metadata = stat()
		if lstat(stateDirectoryURL.path, &metadata) == 0 {
			guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), metadata.st_uid == geteuid() else {
				throw failure(
					"UNSAFE_STATE_DIRECTORY",
					"\(stateDirectoryURL.path) must be a directory owned by the current user and must not be a symbolic link."
				)
			}
		} else if errno == ENOENT {
			guard mkdir(stateDirectoryURL.path, mode_t(S_IRWXU)) == 0 || errno == EEXIST else {
				throw failure("STATE_DIRECTORY_CREATE_FAILED", String(cString: strerror(errno)))
			}
			guard lstat(stateDirectoryURL.path, &metadata) == 0,
				metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
				metadata.st_uid == geteuid()
			else {
				throw failure("UNSAFE_STATE_DIRECTORY", "Could not establish a private state directory.")
			}
		} else {
			throw failure("STATE_DIRECTORY_INSPECTION_FAILED", String(cString: strerror(errno)))
		}
		guard chmod(stateDirectoryURL.path, mode_t(S_IRWXU)) == 0 else {
			throw failure("STATE_DIRECTORY_PERMISSION_FAILED", String(cString: strerror(errno)))
		}
	}

	private static func canConnect(path: String) -> Bool {
		let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0, var address = try? Self.address(path: path) else { return false }
		defer { Darwin.close(fd) }
		return withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
			}
		}
	}
}

// MARK: - App lifecycle and URL scheme

private final class LocalASRLifecycle {
	private let queue = DispatchQueue(label: "com.speek.coding.asr.lifecycle")
	private let label = "com.speek.coding.asr"

	private func launchctl(_ arguments: [String]) -> Bool {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
		process.arguments = arguments
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
			process.waitUntilExit()
			return process.terminationStatus == 0
		} catch {
			NSLog("SpeekCoding: launchctl failed: %@", error.localizedDescription)
			return false
		}
	}

	func start() {
		queue.async { [self] in
			let config = AgentConfig.load()
			guard config.fakeTranscript.isEmpty, let endpoint = URL(string: config.asrAPIURL),
				isLoopbackHost(endpoint.host) else { return }
			let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
			let paths = [
				home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path,
				configFileURL().deletingLastPathComponent().appendingPathComponent("\(label).plist").path,
			]
			guard let plist = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
			let domain = "gui/\(geteuid())"
			let target = "\(domain)/\(label)"
			if !launchctl(["print", target]) && !launchctl(["bootstrap", domain, plist]) {
				NSLog("SpeekCoding: unable to load local transcription service")
				return
			}
			if !launchctl(["kickstart", target]) {
				NSLog("SpeekCoding: unable to start local transcription service")
			}
		}
	}

	func stop() {
		queue.sync {
			_ = launchctl(["bootout", "gui/\(geteuid())/\(label)"])
		}
	}
}

private func statusBarIcon() -> NSImage {
	let icon = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
		NSColor.black.setStroke()
		let path = NSBezierPath()
		path.lineWidth = 1.5
		path.lineCapStyle = .round
		path.lineJoinStyle = .round
		// Code brackets surround a three-bar voice waveform.
		path.move(to: NSPoint(x: 6, y: 13))
		path.line(to: NSPoint(x: 2.5, y: 9))
		path.line(to: NSPoint(x: 6, y: 5))
		path.move(to: NSPoint(x: 18, y: 13))
		path.line(to: NSPoint(x: 21.5, y: 9))
		path.line(to: NSPoint(x: 18, y: 5))
		for (x, halfHeight) in [(9.0, 2.0), (12.0, 4.0), (15.0, 2.0)] {
			path.move(to: NSPoint(x: x, y: 9 - halfHeight))
			path.line(to: NSPoint(x: x, y: 9 + halfHeight))
		}
		path.stroke()
		return true
	}
	icon.isTemplate = true
	icon.accessibilityDescription = "SpeekCoding"
	return icon
}

private final class SpeekCodingApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private let socketServer = UnixSocketServer()
	private let localASR = LocalASRLifecycle()
	private var agentStarted = false
	private var statusItem: NSStatusItem?
	private var downloadingKarabiner = false
	private let karabinerCLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
	private let karabinerWebsite = URL(string: "https://karabiner-elements.pqrs.org/")!
	private let karabinerDownload = URL(string: "https://github.com/pqrs-org/Karabiner-Elements/releases/download/v16.3.0/Karabiner-Elements-16.3.0.dmg")!

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
		let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		item.button?.image = statusBarIcon()
		item.button?.title = item.button?.image == nil ? "Speek" : ""
		let menu = NSMenu()
		menu.delegate = self
		item.menu = menu
		statusItem = item
		signal(SIGPIPE, SIG_IGN)
		do {
			try socketServer.start()
			agentStarted = true
			localASR.start()
		} catch {
			FileHandle.standardError.write(Data("SpeekCoding agent failed to start: \(error.localizedDescription)\n".utf8))
			NSApp.terminate(nil)
		}
	}

	func menuWillOpen(_ menu: NSMenu) {
		menu.removeAllItems()
		let heading = NSMenuItem(title: menuText(.microphoneInput), action: nil, keyEquivalent: "")
		heading.isEnabled = false
		menu.addItem(heading)
		let config = AgentConfig.load()
		let selected = config.audioInputDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
		let defaultItem = NSMenuItem(title: menuText(.systemMicrophone), action: #selector(selectMicrophone(_:)), keyEquivalent: "")
		defaultItem.target = self
		defaultItem.representedObject = ""
		defaultItem.state = selected.isEmpty && config.audioInputDeviceIndex.isEmpty ? .on : .off
		menu.addItem(defaultItem)
		let devices = audioInputDevices().sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
		for device in devices {
			let choice = NSMenuItem(title: device.localizedName, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
			choice.target = self
			choice.representedObject = device.localizedName
			choice.state = device.localizedName.caseInsensitiveCompare(selected) == .orderedSame ? .on : .off
			menu.addItem(choice)
		}
		if !selected.isEmpty && !devices.contains(where: { $0.localizedName.caseInsensitiveCompare(selected) == .orderedSame }) {
			let missing = NSMenuItem(title: menuText(.disconnected, selected), action: nil, keyEquivalent: "")
			missing.isEnabled = false
			missing.state = .on
			menu.addItem(missing)
		}
		menu.addItem(.separator())
		let featuresHeading = NSMenuItem(title: menuText(.featureSettings), action: nil, keyEquivalent: "")
		featuresHeading.isEnabled = false
		menu.addItem(featuresHeading)
		let autoSend = NSMenuItem(title: menuText(.autoSend), action: #selector(toggleAutoSend(_:)), keyEquivalent: "")
		autoSend.target = self
		autoSend.state = config.deliveryMode == "clipboard_only" ? .mixed : (config.deliveryMode == "paste_and_send" ? .on : .off)
		autoSend.toolTip = menuText(.autoSendHelp)
		menu.addItem(autoSend)
		let languageItem = NSMenuItem(title: menuText(.language), action: nil, keyEquivalent: "")
		languageItem.toolTip = menuText(.languageHelp)
		let languages = NSMenu(title: menuText(.language))
		let selectedLanguage = MenuLanguage.selected()
		for language in MenuLanguage.allCases {
			let choice = NSMenuItem(title: language.displayName, action: #selector(selectMenuLanguage(_:)), keyEquivalent: "")
			choice.target = self
			choice.representedObject = language.rawValue
			choice.state = language == selectedLanguage ? .on : .off
			languages.addItem(choice)
		}
		languageItem.submenu = languages
		menu.addItem(languageItem)
		menu.addItem(.separator())
		let permissionsHeading = NSMenuItem(title: menuText(.permissionSettings), action: nil, keyEquivalent: "")
		permissionsHeading.isEnabled = false
		menu.addItem(permissionsHeading)
		let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
		let microphoneLabel: String
		switch microphone {
		case .authorized: microphoneLabel = menuText(.allowed)
		case .notDetermined: microphoneLabel = menuText(.clickToAllow)
		case .restricted: microphoneLabel = menuText(.restricted)
		default: microphoneLabel = menuText(.notAllowed)
		}
		let microphonePermission = NSMenuItem(title: menuText(.microphoneStatus, microphoneLabel), action: #selector(openMicrophonePermission), keyEquivalent: "")
		microphonePermission.target = self
		microphonePermission.toolTip = menuText(.microphoneHelp)
		menu.addItem(microphonePermission)
		let canControlApps = AXIsProcessTrusted()
		let canPostEvents = CGPreflightPostEventAccess()
		let deliveryPermissionStatus = !canControlApps ? menuText(.accessibilityRequired) : (!canPostEvents ? menuText(.eventPostingRequired) : menuText(.allowed))
		let accessibilityPermission = NSMenuItem(title: menuText(.deliveryStatus, deliveryPermissionStatus), action: #selector(openAccessibilityPermission), keyEquivalent: "")
		accessibilityPermission.target = self
		accessibilityPermission.toolTip = menuText(.deliveryHelp)
		menu.addItem(accessibilityPermission)
		menu.addItem(.separator())
		let karabinerInstalled = FileManager.default.isExecutableFile(atPath: karabinerCLI)
		let karabinerTitle = downloadingKarabiner ? menuText(.karabinerDownloading) :
			(karabinerInstalled ? menuText(.karabinerInstalled) : menuText(.karabinerMissing))
		let karabinerItem = NSMenuItem(title: karabinerTitle, action: #selector(openKarabiner), keyEquivalent: "")
		karabinerItem.target = self
		karabinerItem.isEnabled = !downloadingKarabiner
		karabinerItem.toolTip = menuText(.karabinerHelp)
		menu.addItem(karabinerItem)
		menu.addItem(.separator())
		let quit = NSMenuItem(title: menuText(.quit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		menu.addItem(quit)
	}

	private func openPrivacySettings(_ pane: String) {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
		if !NSWorkspace.shared.open(url) {
			NSLog("SpeekCoding: unable to open privacy settings for %@", pane)
		}
	}

	@objc private func openMicrophonePermission() {
		if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
			AVCaptureDevice.requestAccess(for: .audio) { _ in }
		} else {
			openPrivacySettings("Privacy_Microphone")
		}
	}

	@objc private func openAccessibilityPermission() {
		if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
		openPrivacySettings("Privacy_Accessibility")
	}

	@objc private func openKarabiner() {
		if FileManager.default.isExecutableFile(atPath: karabinerCLI) {
			let application = URL(fileURLWithPath: "/Applications/Karabiner-Elements.app")
			if !NSWorkspace.shared.open(application) { showKarabinerError(menuText(.karabinerOpenFailed)) }
			return
		}
		guard !downloadingKarabiner else { return }
		let guide = NSAlert()
		guide.messageText = menuText(.karabinerInstall)
		guide.informativeText = menuText(.karabinerGuide)
		guide.addButton(withTitle: menuText(.downloadInstaller))
		guide.addButton(withTitle: menuText(.cancel))
		guard guide.runModal() == .alertFirstButtonReturn else { return }
		downloadingKarabiner = true
		let task = URLSession.shared.downloadTask(with: karabinerDownload) { [weak self] file, response, error in
			guard let self else { return }
			var temporaryDirectory: URL?
			var mountedImage: URL?
			do {
				if let error { throw error }
				guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
					response.url?.scheme?.lowercased() == "https", let file else {
					throw failure("KARABINER_DOWNLOAD_FAILED", menuText(.downloadFailed))
				}
				let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speek-karabiner-\(UUID().uuidString)", isDirectory: true)
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
				temporaryDirectory = directory
				let image = directory.appendingPathComponent("Karabiner-Elements.dmg")
				try FileManager.default.moveItem(at: file, to: image)
				let mount = directory.appendingPathComponent("mount", isDirectory: true)
				try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
				try self.runInstallerTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, image.path])
				mountedImage = mount
				let package = mount.appendingPathComponent("Karabiner-Elements.pkg")
				let signature = try self.runInstallerTool("/usr/sbin/pkgutil", ["--check-signature", package.path])
				guard signature.contains("signed by a developer certificate issued by Apple for distribution"),
					signature.contains("Developer ID Installer: Fumihiko Takayama (G43BCU2T37)") else {
					throw failure("KARABINER_SIGNATURE_INVALID", menuText(.signatureInvalid))
				}
				try self.runInstallerTool("/usr/sbin/spctl", ["--assess", "--type", "install", package.path])
				DispatchQueue.main.async {
					self.downloadingKarabiner = false
					if !NSWorkspace.shared.open(package) { self.showKarabinerError(menuText(.installerOpenFailed)) }
				}
			} catch {
				if let mount = mountedImage { _ = try? self.runInstallerTool("/usr/bin/hdiutil", ["detach", mount.path]) }
				if let directory = temporaryDirectory { try? FileManager.default.removeItem(at: directory) }
				DispatchQueue.main.async {
					self.downloadingKarabiner = false
					self.showKarabinerError(error.localizedDescription)
				}
			}
		}
		task.resume()
	}

	@discardableResult private func runInstallerTool(_ path: String, _ arguments: [String]) throws -> String {
		let process = Process()
		let output = Pipe()
		process.executableURL = URL(fileURLWithPath: path)
		process.arguments = arguments
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { throw failure("KARABINER_INSTALLER_FAILED", menuText(.installerFailed)) }
		return String(data: data, encoding: .utf8) ?? ""
	}

	private func showKarabinerError(_ message: String) {
		let alert = NSAlert()
		alert.messageText = menuText(.karabinerError)
		alert.informativeText = menuText(.websiteSuggestion, message)
		alert.addButton(withTitle: menuText(.openWebsite))
		alert.addButton(withTitle: menuText(.cancel))
		if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(karabinerWebsite) }
	}

	@objc private func selectMicrophone(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String else { return }
		do { try saveInputDevice(name) }
		catch {
			let alert = NSAlert(error: error)
			alert.messageText = menuText(.microphoneSaveFailed)
			alert.runModal()
		}
	}

	@objc private func selectMenuLanguage(_ sender: NSMenuItem) {
		guard let identifier = sender.representedObject as? String,
			let language = MenuLanguage(rawValue: identifier) else { return }
		UserDefaults.standard.set(language.rawValue, forKey: MenuLanguage.defaultsKey)
		if let menu = statusItem?.menu { menuWillOpen(menu) }
	}

	@objc private func toggleAutoSend(_ sender: NSMenuItem) {
		let mode = sender.state == .on ? "paste_only" : "paste_and_send"
		do { try saveConfigValues(["SPEEK_DELIVERY_MODE": "'\(mode)'"]) }
		catch {
			let alert = NSAlert(error: error)
			alert.messageText = menuText(.autoSendSaveFailed)
			alert.runModal()
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		socketServer.stop()
		SpeekAgent.shared.stopForTermination()
		if agentStarted { localASR.stop() }
	}

	func application(_ application: NSApplication, open urls: [URL]) {
		for url in urls {
			guard url.scheme?.lowercased() == "speekcoding", let request = request(from: url) else { continue }
			SpeekAgent.shared.handle(request) { response in
				if !(response["ok"] as? Bool ?? false),
					let data = try? JSONSerialization.data(withJSONObject: response),
					let text = String(data: data, encoding: .utf8)
				{
					FileHandle.standardError.write(Data("SpeekCoding URL command failed: \(text)\n".utf8))
				}
			}
		}
	}

	private func request(from url: URL) -> JSONObject? {
		let knownCommands = Set(["toggle", "cancel"])
		let host = (url.host ?? "").lowercased()
		let components = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
		let command: String?
		if host == "trigger" {
			command = components.first
		} else if knownCommands.contains(host) {
			command = host
		} else {
			command = components.first(where: knownCommands.contains)
		}
		let expectedToken = readIPCToken()
		guard expectedToken.count == 64, expectedToken.allSatisfy({ $0.isHexDigit }),
			let command, knownCommands.contains(command),
			let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let suppliedToken = urlComponents.queryItems?.first(where: { $0.name == "token" })?.value,
			secureEquals(suppliedToken, expectedToken)
		else { return nil }
		var request: JSONObject = ["command": command]
		if let source = urlComponents.queryItems?.first(where: { $0.name == "source" })?.value
		{
			request["source"] = String(source.prefix(32))
		}
		return request
	}
}

private func runMenuLocalizationSelfTest() {
	let cases: [([String], MenuLanguage)] = [
		(["zh-Hans-CN"], .simplifiedChinese), (["zh-CN"], .simplifiedChinese),
		(["zh-SG"], .simplifiedChinese), (["zh"], .simplifiedChinese),
		(["zh-Hant-TW"], .traditionalChinese), (["zh-TW"], .traditionalChinese),
		(["zh-HK"], .traditionalChinese), (["zh-MO"], .traditionalChinese),
		(["ZH_Hant_HK"], .traditionalChinese), (["zh-Hans-TW"], .simplifiedChinese),
		(["en-US"], .english), (["en-GB", "zh-CN"], .english),
		(["fr-FR", "zh-HK", "en"], .traditionalChinese), (["ja-JP"], .english), ([], .english)
	]
	for (preferences, expected) in cases {
		precondition(MenuLanguage.system.resolved(preferredLanguages: preferences) == expected)
	}
	for language in MenuLanguage.allCases where language != .system {
		precondition(language.resolved(preferredLanguages: ["fr", "zh-CN"]) == language)
		for key in MenuText.allCases {
			let text = key.text(in: language)
			precondition(!text.isEmpty)
			precondition(text.components(separatedBy: "%@").count == key.rawValue.components(separatedBy: "%@").count)
		}
	}
	let domain = "com.speek.coding.localization-test.\(UUID().uuidString)"
	let defaults = UserDefaults(suiteName: domain)!
	defer { defaults.removePersistentDomain(forName: domain) }
	precondition(MenuLanguage.selected(in: defaults) == .system)
	defaults.set(MenuLanguage.traditionalChinese.rawValue, forKey: MenuLanguage.defaultsKey)
	precondition(MenuLanguage.selected(in: UserDefaults(suiteName: domain)!) == .traditionalChinese)
	defaults.set("invalid", forKey: MenuLanguage.defaultsKey)
	precondition(MenuLanguage.selected(in: defaults) == .system)
	defaults.set(MenuLanguage.system.rawValue, forKey: MenuLanguage.defaultsKey)
	precondition(MenuLanguage.selected(in: defaults) == .system)
	print("Menu localization self-test passed (3 languages, system matching, saved preference, and format placeholders).")
}

if CommandLine.arguments.contains("--localization-self-test") {
	runMenuLocalizationSelfTest()
	exit(EXIT_SUCCESS)
}

private let application = NSApplication.shared
private let applicationDelegate = SpeekCodingApplicationDelegate()
application.delegate = applicationDelegate
application.run()
