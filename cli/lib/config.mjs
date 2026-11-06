import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import { isIP } from 'node:net';

export const QWEN_MODEL = 'mlx-community/Qwen3-ASR-0.6B-4bit';
const appleSilicon = process.platform === 'darwin' && process.arch === 'arm64';

export const DEFAULT_CONFIG = Object.freeze({
	audioFeedbackEnabled: true,
	preconfirmSoundName: 'Sosumi',
	readyOverlayEnabled: true,
	reviewWindowSeconds: 3,
	asrApiUrl: 'http://127.0.0.1:8000/v1/audio/transcriptions',
	asrModel: appleSilicon ? QWEN_MODEL : 'whisper-large-v3-turbo',
	asrStreaming: true,
	asrApiKeyEnv: 'ASR_API_KEY',
	asrLanguage: '',
	asrPrompt:
		'中英混合软件工程口述 / Mixed Chinese-English software engineering dictation. 保持说话者原始的中英文切换；preserve code identifiers, commands, filenames, acronyms, product names, and punctuation. 不要互相翻译中英文。',
	asrBackend: appleSilicon ? 'qwen-mlx' : 'faster-whisper',
	asrHost: '127.0.0.1',
	asrPort: 8000,
	asrDevice: 'cpu',
	asrComputeType: 'int8',
	asrCpuThreads: 0,
	asrBeamSize: 3,
	asrBestOf: 1,
	whisperCppBin: '',
	whisperCppTimeout: 120,
	asrVadFilter: true,
	asrQuiet: true,
	fakeTranscript: '',
	audioInputDeviceName: 'DJI Mic Mini',
	audioInputDeviceIndex: '',
	audioSampleRate: 16000,
	deliveryMode: 'paste_and_send',
	pythonBin: '',
	asrHelperPath: '',
});

function parseBoolean(value, fallback) {
	if (value == null || value === '') {
		return fallback;
	}
	const normalized = String(value).trim().toLowerCase();
	if (['1', 'true', 'yes', 'on'].includes(normalized)) {
		return true;
	}
	if (['0', 'false', 'no', 'off'].includes(normalized)) {
		return false;
	}
	return fallback;
}

function parsePositiveNumber(value, fallback) {
	if (value == null || value === '') {
		return fallback;
	}
	const parsed = Number(value);
	if (!Number.isFinite(parsed) || parsed <= 0) {
		return fallback;
	}
	return parsed;
}

function parsePositiveInteger(value, fallback) {
	const parsed = parsePositiveNumber(value, fallback);
	return Number.isInteger(parsed) ? parsed : fallback;
}

function parseNonNegativeInteger(value, fallback) {
	if (value == null || value === '') {
		return fallback;
	}
	const parsed = Number(value);
	return Number.isInteger(parsed) && parsed >= 0 ? parsed : fallback;
}

function parseString(value, fallback) {
	if (value == null) {
		return fallback;
	}
	return String(value);
}

function normalizeDeliveryMode(value, fallback = DEFAULT_CONFIG.deliveryMode) {
	const normalized = parseString(value, fallback).trim().toLowerCase();
	if (['paste_and_send', 'paste_only', 'clipboard_only'].includes(normalized)) {
		return normalized;
	}
	return fallback;
}

function normalizeChoice(value, choices, fallback) {
	const normalized = parseString(value, fallback).trim().toLowerCase();
	return choices.includes(normalized) ? normalized : fallback;
}

function normalizeAsrLanguage(value) {
	const normalized = parseString(value, DEFAULT_CONFIG.asrLanguage).trim();
	return /^(auto|automatic|detect)$/iu.test(normalized) ? '' : normalized;
}

function normalizeAsrHost(value) {
	const normalized = parseString(value, DEFAULT_CONFIG.asrHost).trim().toLowerCase();
	if (
		normalized === 'localhost' ||
		normalized === '::1' ||
		(normalized.startsWith('127.') && isIP(normalized) === 4)
	) {
		return normalized;
	}
	return DEFAULT_CONFIG.asrHost;
}

export function normalizeSoundName(value, fallback = DEFAULT_CONFIG.preconfirmSoundName) {
	if (value === undefined || value === null) {
		return fallback;
	}
	const raw = String(value).trim();
	if (raw === '' || /^(off|none)$/iu.test(raw)) {
		return '';
	}
	const normalized = raw.replace(/\.aiff$/iu, '');
	if (!normalized || /[\0\r\n/]/u.test(normalized)) {
		return fallback;
	}
	return normalized;
}

export function normalizeConfig(config = {}) {
	const preconfirmSoundName = normalizeSoundName(config.preconfirmSoundName, DEFAULT_CONFIG.preconfirmSoundName);
	const derivedAudioFeedbackEnabled = preconfirmSoundName !== '';
	const asrBackend = normalizeChoice(config.asrBackend, ['qwen-mlx', 'faster-whisper', 'whisper-cpp'], DEFAULT_CONFIG.asrBackend);
	return {
		audioFeedbackEnabled: parseBoolean(config.audioFeedbackEnabled, derivedAudioFeedbackEnabled),
		preconfirmSoundName,
		readyOverlayEnabled: parseBoolean(config.readyOverlayEnabled, DEFAULT_CONFIG.readyOverlayEnabled),
		reviewWindowSeconds: parsePositiveNumber(config.reviewWindowSeconds, DEFAULT_CONFIG.reviewWindowSeconds),
		asrApiUrl: parseString(config.asrApiUrl, DEFAULT_CONFIG.asrApiUrl).trim(),
		asrModel: parseString(config.asrModel, asrBackend === 'qwen-mlx' ? QWEN_MODEL : 'whisper-large-v3-turbo').trim(),
		asrStreaming: parseBoolean(config.asrStreaming, DEFAULT_CONFIG.asrStreaming),
		asrApiKeyEnv: parseString(config.asrApiKeyEnv, DEFAULT_CONFIG.asrApiKeyEnv).trim(),
		asrLanguage: normalizeAsrLanguage(config.asrLanguage),
		asrPrompt: parseString(config.asrPrompt, DEFAULT_CONFIG.asrPrompt),
		asrBackend,
		asrHost: normalizeAsrHost(config.asrHost),
		asrPort: parsePositiveInteger(config.asrPort, DEFAULT_CONFIG.asrPort),
		asrDevice: parseString(config.asrDevice, DEFAULT_CONFIG.asrDevice).trim(),
		asrComputeType: parseString(config.asrComputeType, DEFAULT_CONFIG.asrComputeType).trim(),
		asrCpuThreads: parseNonNegativeInteger(config.asrCpuThreads, DEFAULT_CONFIG.asrCpuThreads),
		asrBeamSize: parsePositiveInteger(config.asrBeamSize, DEFAULT_CONFIG.asrBeamSize),
		asrBestOf: parsePositiveInteger(config.asrBestOf, DEFAULT_CONFIG.asrBestOf),
		whisperCppBin: parseString(config.whisperCppBin, DEFAULT_CONFIG.whisperCppBin).trim(),
		whisperCppTimeout: parsePositiveNumber(config.whisperCppTimeout, DEFAULT_CONFIG.whisperCppTimeout),
		asrVadFilter: parseBoolean(config.asrVadFilter, DEFAULT_CONFIG.asrVadFilter),
		asrQuiet: parseBoolean(config.asrQuiet, DEFAULT_CONFIG.asrQuiet),
		fakeTranscript: parseString(config.fakeTranscript, DEFAULT_CONFIG.fakeTranscript),
		audioInputDeviceName: parseString(config.audioInputDeviceName, DEFAULT_CONFIG.audioInputDeviceName).trim(),
		audioInputDeviceIndex: parseString(config.audioInputDeviceIndex, DEFAULT_CONFIG.audioInputDeviceIndex).trim(),
		audioSampleRate: parsePositiveNumber(config.audioSampleRate, DEFAULT_CONFIG.audioSampleRate),
		deliveryMode: normalizeDeliveryMode(config.deliveryMode, DEFAULT_CONFIG.deliveryMode),
		pythonBin: parseString(config.pythonBin, DEFAULT_CONFIG.pythonBin).trim(),
		asrHelperPath: parseString(config.asrHelperPath, DEFAULT_CONFIG.asrHelperPath).trim(),
	};
}

function parseEnvFile(text) {
	const result = {};
	for (const rawLine of text.split(/\r?\n/u)) {
		const line = rawLine.trim();
		if (!line || line.startsWith('#')) {
			continue;
		}
		const separatorIndex = line.indexOf('=');
		if (separatorIndex === -1) {
			continue;
		}
		const key = line.slice(0, separatorIndex).trim();
		let value = line.slice(separatorIndex + 1).trim();
		if (
			(value.startsWith('"') && value.endsWith('"')) ||
			(value.startsWith("'") && value.endsWith("'"))
		) {
			value = value.slice(1, -1);
		}
		result[key] = value;
	}
	return result;
}

function serializeEnvValue(value) {
	return value ? '1' : '0';
}

function serializeEnvString(value) {
	return `'${String(value).replace(/'/gu, `'"'"'`)}'`;
}

function serializeEnvNumber(value) {
	return String(value);
}

export async function loadConfig(runtime) {
	try {
		const raw = await fs.readFile(runtime.configFilePath, 'utf-8');
		const env = parseEnvFile(raw);
		return normalizeConfig({
			audioFeedbackEnabled: env.SPEEK_AUDIO_FEEDBACK_ENABLED ?? env.DJI_ENABLE_AUDIO_FEEDBACK,
			preconfirmSoundName: env.SPEEK_PRECONFIRM_SOUND_NAME ?? env.DJI_PRECONFIRM_SOUND_NAME,
			readyOverlayEnabled: env.SPEEK_READY_OVERLAY_ENABLED ?? env.DJI_ENABLE_READY_HUD,
			reviewWindowSeconds: env.SPEEK_REVIEW_WINDOW_SECONDS ?? env.DJI_REVIEW_WINDOW_SECONDS,
			asrApiUrl: env.SPEEK_ASR_API_URL,
			asrModel: env.SPEEK_ASR_MODEL,
			asrStreaming: env.SPEEK_ASR_STREAMING,
			asrApiKeyEnv: env.SPEEK_ASR_API_KEY_ENV,
			asrLanguage: env.SPEEK_ASR_LANGUAGE,
			asrPrompt: env.SPEEK_ASR_PROMPT,
			asrBackend: env.SPEEK_ASR_BACKEND,
			asrHost: env.SPEEK_ASR_HOST,
			asrPort: env.SPEEK_ASR_PORT,
			asrDevice: env.SPEEK_ASR_DEVICE,
			asrComputeType: env.SPEEK_ASR_COMPUTE_TYPE,
			asrCpuThreads: env.SPEEK_ASR_CPU_THREADS,
			asrBeamSize: env.SPEEK_ASR_BEAM_SIZE,
			asrBestOf: env.SPEEK_ASR_BEST_OF,
			whisperCppBin: env.SPEEK_WHISPER_CPP_BIN,
			whisperCppTimeout: env.SPEEK_WHISPER_CPP_TIMEOUT,
			asrVadFilter: env.SPEEK_ASR_VAD_FILTER,
			asrQuiet: env.SPEEK_ASR_QUIET,
			fakeTranscript: env.SPEEK_FAKE_TRANSCRIPT,
			audioInputDeviceName: env.SPEEK_AUDIO_INPUT_DEVICE_NAME,
			audioInputDeviceIndex: env.SPEEK_AUDIO_INPUT_DEVICE_INDEX,
			audioSampleRate: env.SPEEK_AUDIO_SAMPLE_RATE,
			deliveryMode: env.SPEEK_DELIVERY_MODE,
			pythonBin: env.SPEEK_PYTHON_BIN,
			asrHelperPath: env.SPEEK_ASR_HELPER_PATH,
		});
	} catch (error) {
		if (error.code === 'ENOENT') {
			return { ...DEFAULT_CONFIG };
		}
		throw error;
	}
}

export async function writeConfig(runtime, config) {
	const normalized = normalizeConfig(config);
	await fs.mkdir(runtime.configDir, { recursive: true, mode: 0o700 });
	await fs.chmod(runtime.configDir, 0o700);
	const content = [
		'# Managed by Speek. Edit with `speek config`.',
		`SPEEK_AUDIO_FEEDBACK_ENABLED=${serializeEnvValue(normalized.audioFeedbackEnabled)}`,
		`SPEEK_PRECONFIRM_SOUND_NAME=${serializeEnvString(normalized.preconfirmSoundName)}`,
		`SPEEK_READY_OVERLAY_ENABLED=${serializeEnvValue(normalized.readyOverlayEnabled)}`,
		`SPEEK_REVIEW_WINDOW_SECONDS=${serializeEnvNumber(normalized.reviewWindowSeconds)}`,
		`SPEEK_ASR_API_URL=${serializeEnvString(normalized.asrApiUrl)}`,
		`SPEEK_ASR_MODEL=${serializeEnvString(normalized.asrModel)}`,
		`SPEEK_ASR_STREAMING=${serializeEnvValue(normalized.asrStreaming)}`,
		`SPEEK_ASR_API_KEY_ENV=${serializeEnvString(normalized.asrApiKeyEnv)}`,
		`SPEEK_ASR_LANGUAGE=${serializeEnvString(normalized.asrLanguage)}`,
		`SPEEK_ASR_PROMPT=${serializeEnvString(normalized.asrPrompt)}`,
		`SPEEK_ASR_BACKEND=${serializeEnvString(normalized.asrBackend)}`,
		`SPEEK_ASR_HOST=${serializeEnvString(normalized.asrHost)}`,
		`SPEEK_ASR_PORT=${serializeEnvNumber(normalized.asrPort)}`,
		`SPEEK_ASR_DEVICE=${serializeEnvString(normalized.asrDevice)}`,
		`SPEEK_ASR_COMPUTE_TYPE=${serializeEnvString(normalized.asrComputeType)}`,
		`SPEEK_ASR_CPU_THREADS=${serializeEnvNumber(normalized.asrCpuThreads)}`,
		`SPEEK_ASR_BEAM_SIZE=${serializeEnvNumber(normalized.asrBeamSize)}`,
		`SPEEK_ASR_BEST_OF=${serializeEnvNumber(normalized.asrBestOf)}`,
		`SPEEK_WHISPER_CPP_BIN=${serializeEnvString(normalized.whisperCppBin)}`,
		`SPEEK_WHISPER_CPP_TIMEOUT=${serializeEnvNumber(normalized.whisperCppTimeout)}`,
		`SPEEK_ASR_VAD_FILTER=${serializeEnvValue(normalized.asrVadFilter)}`,
		`SPEEK_ASR_QUIET=${serializeEnvValue(normalized.asrQuiet)}`,
		`SPEEK_FAKE_TRANSCRIPT=${serializeEnvString(normalized.fakeTranscript)}`,
		`SPEEK_AUDIO_INPUT_DEVICE_NAME=${serializeEnvString(normalized.audioInputDeviceName)}`,
		`SPEEK_AUDIO_INPUT_DEVICE_INDEX=${serializeEnvString(normalized.audioInputDeviceIndex)}`,
		`SPEEK_AUDIO_SAMPLE_RATE=${serializeEnvNumber(normalized.audioSampleRate)}`,
		`SPEEK_DELIVERY_MODE=${serializeEnvString(normalized.deliveryMode)}`,
		`SPEEK_PYTHON_BIN=${serializeEnvString(normalized.pythonBin)}`,
		`SPEEK_ASR_HELPER_PATH=${serializeEnvString(normalized.asrHelperPath)}`,
		'',
	].join('\n');
	const temporaryPath = `${runtime.configFilePath}.${process.pid}.${randomUUID()}.tmp`;
	try {
		await fs.writeFile(temporaryPath, content, { encoding: 'utf-8', flag: 'wx', mode: 0o600 });
		await fs.rename(temporaryPath, runtime.configFilePath);
		await fs.chmod(runtime.configFilePath, 0o600);
	} finally {
		await fs.rm(temporaryPath, { force: true });
	}
	return normalized;
}
