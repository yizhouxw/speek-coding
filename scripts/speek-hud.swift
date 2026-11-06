#!/usr/bin/env swift
import AppKit
import Darwin
import Foundation

private struct HudScreenGeometry {
	let frame: NSRect
	let visibleFrame: NSRect
	let safeTopInset: CGFloat
	let auxiliaryTopLeftArea: NSRect?
	let auxiliaryTopRightArea: NSRect?

	init(screen: NSScreen) {
		frame = screen.frame
		visibleFrame = screen.visibleFrame
		safeTopInset = screen.safeAreaInsets.top
		auxiliaryTopLeftArea = screen.auxiliaryTopLeftArea
		auxiliaryTopRightArea = screen.auxiliaryTopRightArea
	}

	init(
		frame: NSRect,
		visibleFrame: NSRect,
		safeTopInset: CGFloat,
		auxiliaryTopLeftArea: NSRect?,
		auxiliaryTopRightArea: NSRect?
	) {
		self.frame = frame
		self.visibleFrame = visibleFrame
		self.safeTopInset = safeTopInset
		self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
		self.auxiliaryTopRightArea = auxiliaryTopRightArea
	}

	var hardwareNotchRect: NSRect? {
		guard safeTopInset >= 8,
			let leftArea = auxiliaryTopLeftArea,
			let rightArea = auxiliaryTopRightArea
		else { return nil }

		let notchWidth = rightArea.minX - leftArea.maxX
		let notchBottom = max(frame.maxY - safeTopInset, min(leftArea.minY, rightArea.minY))
		let notchHeight = frame.maxY - notchBottom
		guard notchWidth >= 40, notchHeight >= 8 else { return nil }

		return NSRect(x: leftArea.maxX, y: notchBottom, width: notchWidth, height: notchHeight)
	}
}

private struct HudLayout {
	static let fallbackSize = NSSize(width: 336, height: 56)
	static let hardwareMinimumWidth: CGFloat = 420
	static let hardwareSideContentWidth: CGFloat = 130
	static let hardwareBottomExtension: CGFloat = 28

	let windowFrame: NSRect
	let hardwareNotchRect: NSRect?

	var isAttachedToHardwareNotch: Bool {
		hardwareNotchRect != nil
	}

	static func make(for screen: HudScreenGeometry) -> HudLayout {
		guard let notch = screen.hardwareNotchRect else {
			let frame = NSRect(
				x: screen.visibleFrame.midX - fallbackSize.width / 2,
				y: screen.visibleFrame.maxY - fallbackSize.height - 10,
				width: fallbackSize.width,
				height: fallbackSize.height
			)
			return HudLayout(windowFrame: frame, hardwareNotchRect: nil)
		}

		let maximumWidth = max(1, screen.frame.width - 40)
		let desiredWidth = max(hardwareMinimumWidth, notch.width + hardwareSideContentWidth * 2)
		let width = min(maximumWidth, desiredWidth)
		let height = max(60, notch.height + hardwareBottomExtension)
		let centeredX = notch.midX - width / 2
		let x = min(max(centeredX, screen.frame.minX), screen.frame.maxX - width)
		let frame = NSRect(x: x, y: screen.frame.maxY - height, width: width, height: height)
		return HudLayout(windowFrame: frame, hardwareNotchRect: notch)
	}
}

final class PillView: NSView {
	var isAttachedToHardwareNotch = false {
		didSet { needsDisplay = true }
	}

	override func draw(_ dirtyRect: NSRect) {
		let background = isAttachedToHardwareNotch
			? NSColor(calibratedWhite: 0, alpha: 0.99)
			: NSColor(calibratedWhite: 0.04, alpha: 0.92)
		background.setFill()
		let radius: CGFloat = isAttachedToHardwareNotch ? 18 : 27
		let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
		path.fill()

		if !isAttachedToHardwareNotch {
			NSColor.white.withAlphaComponent(0.14).setStroke()
			path.lineWidth = 1
			path.stroke()
		}
	}
}

final class DotView: NSView {
	var color = NSColor.systemRed {
		didSet { needsDisplay = true }
	}

	override func draw(_ dirtyRect: NSRect) {
		color.setFill()
		NSBezierPath(ovalIn: bounds).fill()
	}
}

final class LevelMeterView: NSView {
	var levels = Array(repeating: 0.0, count: 18) {
		didSet { needsDisplay = true }
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.white.withAlphaComponent(0.08).setFill()
		NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

		let barCount = max(1, levels.count)
		let gap: CGFloat = 2
		let barWidth = max(2, (bounds.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount))
		for (index, rawLevel) in levels.enumerated() {
			let level = max(0.02, min(1.0, rawLevel))
			let height = max(2, bounds.height * CGFloat(level))
			let x = CGFloat(index) * (barWidth + gap)
			let y = (bounds.height - height) / 2
			let alpha = 0.28 + 0.62 * CGFloat(level)
			NSColor.systemGreen.withAlphaComponent(alpha).setFill()
			NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: height), xRadius: 1.5, yRadius: 1.5).fill()
		}
	}
}

final class HudController: NSObject, NSApplicationDelegate {
	private let stateDir: URL
	private var window: NSPanel!
	private var pillView: PillView!
	private let dot = DotView(frame: .zero)
	private let titleLabel = NSTextField(labelWithString: "Listening")
	private let detailLabel = NSTextField(labelWithString: "Microphone")
	private let timeLabel = NSTextField(labelWithString: "00:00")
	private let levelMeter = LevelMeterView(frame: .zero)
	private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
	private let parentPID: pid_t
	private var timer: Timer?
	private var lastStatus = ""
	private var finalStatusStartedAt: Date?

	init(stateDir: URL, parentPID: pid_t) {
		self.stateDir = stateDir
		self.parentPID = parentPID
		super.init()
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)

		guard let initialLayout = preferredLayout() else {
			NSApp.terminate(nil)
			return
		}

		let frame = NSRect(origin: .zero, size: initialLayout.windowFrame.size)
		let view = PillView(frame: frame)
		view.wantsLayer = true
		pillView = view

		titleLabel.textColor = .white
		titleLabel.backgroundColor = .clear
		titleLabel.lineBreakMode = .byTruncatingTail

		detailLabel.textColor = NSColor.white.withAlphaComponent(0.62)
		detailLabel.backgroundColor = .clear
		detailLabel.lineBreakMode = .byTruncatingHead

		timeLabel.textColor = .white
		timeLabel.alignment = .right
		timeLabel.backgroundColor = .clear

		view.addSubview(dot)
		view.addSubview(titleLabel)
		view.addSubview(detailLabel)
		view.addSubview(timeLabel)
		view.addSubview(levelMeter)
		cancelButton.target = self
		cancelButton.action = #selector(cancelSession)
		cancelButton.bezelStyle = .rounded
		cancelButton.font = .systemFont(ofSize: 11, weight: .medium)
		view.addSubview(cancelButton)

		window = NSPanel(
			contentRect: frame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		window.contentView = view
		window.backgroundColor = .clear
		window.isOpaque = false
		window.hasShadow = true
		window.ignoresMouseEvents = false
		window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
		positionWindow()
		window.orderFrontRegardless()
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(screenParametersDidChange),
			name: NSApplication.didChangeScreenParametersNotification,
			object: nil
		)

		timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
			self?.refresh()
		}
		refresh()
	}

	private func preferredLayout() -> HudLayout? {
		let screens = NSScreen.screens
		guard !screens.isEmpty else { return nil }

		if let mainScreen = NSScreen.main {
			let mainLayout = HudLayout.make(for: HudScreenGeometry(screen: mainScreen))
			if mainLayout.isAttachedToHardwareNotch {
				return mainLayout
			}
		}

		for screen in screens {
			let layout = HudLayout.make(for: HudScreenGeometry(screen: screen))
			if layout.isAttachedToHardwareNotch {
				return layout
			}
		}

		let fallbackScreen = NSScreen.main ?? screens[0]
		return HudLayout.make(for: HudScreenGeometry(screen: fallbackScreen))
	}

	private func positionWindow() {
		guard let layout = preferredLayout() else { return }
		window.setFrame(layout.windowFrame, display: false)
		pillView.frame = NSRect(origin: .zero, size: layout.windowFrame.size)
		pillView.isAttachedToHardwareNotch = layout.isAttachedToHardwareNotch
		window.level = layout.isAttachedToHardwareNotch
			? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
			: .statusBar
		applyContentLayout(layout)
	}

	private func applyContentLayout(_ layout: HudLayout) {
		let size = layout.windowFrame.size
		guard let notch = layout.hardwareNotchRect else {
			dot.frame = NSRect(x: 22, y: 23, width: 10, height: 10)
			titleLabel.frame = NSRect(x: 42, y: 11, width: 190, height: 18)
			titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
			titleLabel.alignment = .left
			detailLabel.frame = NSRect(x: 42, y: 31, width: 190, height: 15)
			detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
			detailLabel.alignment = .left
			timeLabel.frame = NSRect(x: 242, y: 15, width: 72, height: 26)
			timeLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
			levelMeter.frame = NSRect(x: 42, y: 6, width: 190, height: 6)
			cancelButton.frame = NSRect(x: 250, y: 1, width: 72, height: 22)
			timeLabel.frame = NSRect(x: 242, y: 28, width: 72, height: 24)
			return
		}

		let localNotchMinX = notch.minX - layout.windowFrame.minX
		let localNotchMaxX = notch.maxX - layout.windowFrame.minX
		let bottomExtension = size.height - notch.height
		let statusRowY = bottomExtension + max(0, (notch.height - 22) / 2)

		dot.frame = NSRect(x: max(16, localNotchMinX - 112), y: statusRowY + 6, width: 10, height: 10)
		titleLabel.frame = NSRect(
			x: dot.frame.maxX + 8,
			y: statusRowY + 2,
			width: max(48, localNotchMinX - dot.frame.maxX - 16),
			height: 18
		)
		titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
		titleLabel.alignment = .left

		timeLabel.frame = NSRect(
			x: localNotchMaxX + 12,
			y: statusRowY,
			width: max(54, size.width - localNotchMaxX - 28),
			height: 22
		)
		timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)

		detailLabel.frame = NSRect(x: 24, y: 8, width: max(1, size.width - 118), height: 14)
		cancelButton.frame = NSRect(x: size.width - 88, y: 5, width: 72, height: 22)
		detailLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
		detailLabel.alignment = .center
		levelMeter.frame = NSRect(x: 42, y: 2, width: max(1, size.width - 84), height: 4)
	}

	@objc private func screenParametersDidChange(_ notification: Notification) {
		positionWindow()
	}

	private func state(_ name: String) -> String {
		let url = stateDir.appendingPathComponent(name)
		return (try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
	}

	private func epoch(_ name: String) -> TimeInterval? {
		Double(state(name))
	}

	private func elapsedText(from startedAt: TimeInterval) -> String {
		let elapsed = max(0, Int(Date().timeIntervalSince1970 - startedAt))
		return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
	}

	private func countdownText(until expiresAt: TimeInterval) -> String {
		let remaining = max(0, Int(ceil(expiresAt - Date().timeIntervalSince1970)))
		return "\(remaining)s"
	}

	private func waveformLevels() -> [Double] {
		let values = state("audio_waveform")
			.split(separator: ",")
			.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
		if values.isEmpty {
			return Array(repeating: 0.0, count: 18)
		}
		return Array(values.suffix(18))
	}

	@objc private func cancelSession() {
		let session = state("session_id")
		guard !session.isEmpty else { return }
		try? Data(session.utf8).write(to: stateDir.appendingPathComponent("hud_cancel_request"), options: .atomic)
		cancelButton.isEnabled = false
	}

	private func refresh() {
		if parentPID > 1 && getppid() != parentPID {
			NSApp.terminate(nil)
			return
		}
		let status = state("hud_status")
		if status == "hidden" || status.isEmpty {
			NSApp.terminate(nil)
			return
		}

		if status != lastStatus {
			lastStatus = status
			finalStatusStartedAt = nil
			cancelButton.isEnabled = true
		}

		cancelButton.isHidden = !["recording", "transcribing", "downloading", "loading"].contains(status)
		let detail = state("hud_detail")
		let liveText = state("live_transcript")
		let startedAt = epoch("hud_started_at") ?? Date().timeIntervalSince1970
		let expiresAt = epoch("hud_expires_at")

		switch status {
		case "recording":
			dot.color = .systemRed
			titleLabel.stringValue = "Listening"
			detailLabel.stringValue = liveText.isEmpty ? (detail.isEmpty ? "Microphone" : detail) : liveText
			timeLabel.stringValue = elapsedText(from: startedAt)
			levelMeter.isHidden = false
			levelMeter.levels = waveformLevels()
		case "transcribing":
			dot.color = .systemBlue
			titleLabel.stringValue = "Transcribing"
			detailLabel.stringValue = liveText.isEmpty ? (detail.isEmpty ? "Finalizing text" : detail) : liveText
			timeLabel.stringValue = elapsedText(from: startedAt)
			levelMeter.isHidden = true
		case "downloading", "loading":
			dot.color = .systemBlue
			titleLabel.stringValue = status == "downloading" ? "Downloading model" : "Loading model"
			detailLabel.stringValue = detail.isEmpty ? "Press Fn to cancel" : detail
			timeLabel.stringValue = elapsedText(from: startedAt)
			levelMeter.isHidden = true
		case "ready":
			dot.color = .systemGreen
			titleLabel.stringValue = "Ready to send"
			detailLabel.stringValue = detail.isEmpty ? "Press again to send" : detail
			timeLabel.stringValue = expiresAt.map(countdownText) ?? "ready"
			levelMeter.isHidden = true
		case "sent":
			dot.color = .systemGreen
			titleLabel.stringValue = "Sent"
			detailLabel.stringValue = detail.isEmpty ? "Prompt submitted" : detail
			timeLabel.stringValue = "done"
			levelMeter.isHidden = true
			terminateAfterFinalDelay()
		case "error":
			dot.color = .systemOrange
			titleLabel.stringValue = "Error"
			detailLabel.stringValue = detail.isEmpty ? "Check debug.log" : detail
			timeLabel.stringValue = "!"
			levelMeter.isHidden = true
			terminateAfterFinalDelay()
		case "permission":
			dot.color = .systemOrange
			titleLabel.stringValue = "Permission"
			detailLabel.stringValue = detail.isEmpty ? "Allow Accessibility" : detail
			timeLabel.stringValue = "!"
			levelMeter.isHidden = true
			terminateAfterFinalDelay()
		case "nospeech":
			dot.color = .systemOrange
			titleLabel.stringValue = "No sound"
			detailLabel.stringValue = detail.isEmpty ? "Mic level is flat" : detail
			timeLabel.stringValue = ""
			levelMeter.isHidden = true
			terminateAfterFinalDelay()
		case "timeout":
			dot.color = .systemOrange
			titleLabel.stringValue = "Timed out"
			detailLabel.stringValue = detail
			timeLabel.stringValue = ""
			levelMeter.isHidden = true
			terminateAfterFinalDelay()
		case "canceled":
			dot.color = .systemGray
			titleLabel.stringValue = "Canceled"
			detailLabel.stringValue = detail
			timeLabel.stringValue = ""
			levelMeter.isHidden = true
			terminateAfterFinalDelay()
		default:
			dot.color = .systemPurple
			titleLabel.stringValue = status
			detailLabel.stringValue = detail
			timeLabel.stringValue = elapsedText(from: startedAt)
			levelMeter.isHidden = true
		}
	}

	private func terminateAfterFinalDelay() {
		if finalStatusStartedAt == nil {
			finalStatusStartedAt = Date()
		}
		if let started = finalStatusStartedAt, Date().timeIntervalSince(started) > 1.4 {
			NSApp.terminate(nil)
		}
	}
}

func argumentValue(_ name: String, default fallback: String) -> String {
	let args = CommandLine.arguments
	for index in args.indices where args[index] == name && index + 1 < args.count {
		return args[index + 1]
	}
	return fallback
}

private func runLayoutSelfTest() {
	let notchedScreen = HudScreenGeometry(
		frame: NSRect(x: 0, y: 0, width: 1800, height: 1169),
		visibleFrame: NSRect(x: 0, y: 112, width: 1800, height: 1018),
		safeTopInset: 38,
		auxiliaryTopLeftArea: NSRect(x: 0, y: 1131, width: 790, height: 38),
		auxiliaryTopRightArea: NSRect(x: 1010, y: 1131, width: 790, height: 38)
	)
	let hardwareLayout = HudLayout.make(for: notchedScreen)
	precondition(hardwareLayout.isAttachedToHardwareNotch)
	precondition(hardwareLayout.hardwareNotchRect?.width == 220)
	precondition(hardwareLayout.windowFrame.width == 480)
	precondition(hardwareLayout.windowFrame.height == 66)
	precondition(hardwareLayout.windowFrame.maxY == notchedScreen.frame.maxY)

	let regularScreen = HudScreenGeometry(
		frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
		visibleFrame: NSRect(x: 0, y: 23, width: 1920, height: 1057),
		safeTopInset: 0,
		auxiliaryTopLeftArea: nil,
		auxiliaryTopRightArea: nil
	)
	let fallbackLayout = HudLayout.make(for: regularScreen)
	precondition(!fallbackLayout.isAttachedToHardwareNotch)
	precondition(fallbackLayout.windowFrame.size == HudLayout.fallbackSize)
	precondition(fallbackLayout.windowFrame.origin == NSPoint(x: 792, y: 1014))
	print("Speek HUD layout self-test passed.")
}

if CommandLine.arguments.contains("--layout-self-test") {
	runLayoutSelfTest()
	exit(EXIT_SUCCESS)
}

let stateDir = URL(fileURLWithPath: argumentValue("--state-dir", default: "/tmp/speek-coding"), isDirectory: true)
let app = NSApplication.shared
let delegate = HudController(stateDir: stateDir, parentPID: pid_t(argumentValue("--parent-pid", default: "0")) ?? 0)
app.delegate = delegate
app.run()
