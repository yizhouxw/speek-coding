#!/usr/bin/env node

import { execFile as execFileCallback, spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import process from 'node:process';
import { promisify } from 'node:util';

import {
	cancel,
	confirm,
	intro,
	isCancel,
	log,
	note,
	outro,
	select,
	spinner,
	text,
} from '@clack/prompts';

import {
	configureInstallation,
	DEFAULT_CONFIG,
	detectOptionalTriggerDevice,
	doctor,
	getKarabinerProfiles,
	install,
	installAsrRuntime,
	mergeConfig,
	readManifest,
	testRecord,
	uninstall,
	update,
} from './lib/actions.mjs';
import { HELP_TEXT, parseArgs } from './lib/args.mjs';
import { sendAgentCommand } from './lib/agent.mjs';
import { loadConfig, QWEN_MODEL } from './lib/config.mjs';
import { buildInstallProfilePromptPlan } from './lib/install-profile-plan.mjs';
import {
	getBlockingPermissionIssues,
	getInstallPermissionReminderIssues,
} from './lib/install-permissions.mjs';
import { detectPermissions, requestPermissions } from './lib/permissions.mjs';
import { createRuntime } from './lib/runtime.mjs';
import {
	getAsrServiceStatus,
	installAsrService,
	restartAsrService,
	startAsrService,
	stopAsrService,
} from './lib/service.mjs';
import { listSystemSounds } from './lib/sounds.mjs';

const execFile = promisify(execFileCallback);

const KARABINER_APP_NAME = 'Karabiner-Elements';
const KARABINER_DOWNLOAD_URL = 'https://karabiner-elements.pqrs.org/';
const ACCESSIBILITY_SETTINGS_URL = 'x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_Accessibility';
const INPUT_MONITORING_SETTINGS_URL = 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent';
const MICROPHONE_SETTINGS_URL = 'x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_Microphone';
const KARABINER_READY_TIMEOUT_MS = 8000;
const KARABINER_RECHECK_TIMEOUT_MS = 2000;
const FILE_WAIT_INTERVAL_MS = 200;

function formatTriggerMode(triggerMode) {
	return triggerMode === 'keyboard+dji' ? 'keyboard workflow + DJI Mic Mini trigger' : 'keyboard workflow only';
}

const ANSI_GRAY = '\u001B[90m';
const ANSI_RESET = '\u001B[39m\u001B[22m';

function formatSecondaryPromptHint(text) {
	return process.stdout.isTTY ? `${ANSI_GRAY}${text}${ANSI_RESET}` : text;
}

function buildPromptMessage(title, hint) {
	if (!hint) {
		return title;
	}
	return `${title} ${formatSecondaryPromptHint(`(${hint})`)}`;
}

function formatSoundDefaultLabel(soundName) {
	return soundName ? soundName : 'Off';
}

function printExistingInstallSummary({ profileName, triggerMode }) {
	const lines = ['Existing installation found'];
	if (profileName) {
		lines.push(`Profile: ${profileName}`);
	}
	if (triggerMode) {
		lines.push(`Trigger: ${formatTriggerMode(triggerMode)}`);
	}
	note(lines.join('\n'), 'Reusing existing install');
}

function buildProfileOverrides(flags) {
	if (flags.cloneProfileFrom || flags.newProfileName) {
		if (!flags.cloneProfileFrom || !flags.newProfileName) {
			throw new Error('Both --clone-profile-from and --new-profile-name are required when cloning a Karabiner profile.');
		}
		if (flags.profileName) {
			throw new Error('Use either --profile or the clone profile flags, not both.');
		}
		return {
			profileStrategy: 'clone',
			sourceProfileName: flags.cloneProfileFrom,
			newProfileName: flags.newProfileName,
		};
	}
	if (flags.profileName) {
		return {
			profileStrategy: 'existing',
			profileName: flags.profileName,
		};
	}
	return null;
}

function parseToggle(value, key) {
	if (value == null) {
		return undefined;
	}
	const normalized = String(value).trim().toLowerCase();
	if (['1', 'true', 'yes', 'on'].includes(normalized)) {
		return true;
	}
	if (['0', 'false', 'no', 'off'].includes(normalized)) {
		return false;
	}
	throw new Error(`Invalid value for ${key}: ${value}`);
}

function parsePositiveNumberFlag(value, key) {
	if (value == null) {
		return undefined;
	}
	const parsed = Number(value);
	if (!Number.isFinite(parsed) || parsed <= 0) {
		throw new Error(`Invalid value for ${key}: ${value}`);
	}
	return parsed;
}

function parsePositiveIntegerFlag(value, key) {
	const parsed = parsePositiveNumberFlag(value, key);
	if (parsed != null && !Number.isInteger(parsed)) {
		throw new Error(`Invalid value for ${key}: ${value}`);
	}
	return parsed;
}

function parseNonNegativeIntegerFlag(value, key) {
	if (value == null) {
		return undefined;
	}
	const parsed = Number(value);
	if (!Number.isInteger(parsed) || parsed < 0) {
		throw new Error(`Invalid value for ${key}: ${value}`);
	}
	return parsed;
}

function parseChoiceFlag(value, key, choices) {
	if (value == null) {
		return undefined;
	}
	const normalized = String(value).trim().toLowerCase();
	if (!choices.includes(normalized)) {
		throw new Error(`Invalid value for ${key}: ${value}. Expected ${choices.join(' or ')}.`);
	}
	return normalized;
}

function buildConfigOverrides(flags) {
	const overrides = {};
	const audioFeedbackEnabled = parseToggle(flags.sound, '--sound');
	const transcriptCleanup = parseToggle(flags.transcriptCleanup, '--transcript-cleanup');
	if (transcriptCleanup != null) overrides.transcriptCleanup = transcriptCleanup;
	const readyOverlayEnabled = parseToggle(flags.readyOverlay, '--ready-overlay');
	const reviewWindowSeconds = parsePositiveNumberFlag(flags.reviewWindow, '--review-window');
	if (audioFeedbackEnabled === false) {
		overrides.audioFeedbackEnabled = audioFeedbackEnabled;
		overrides.preconfirmSoundName = '';
	} else if (audioFeedbackEnabled === true) {
		overrides.audioFeedbackEnabled = audioFeedbackEnabled;
		if (flags.preconfirmSoundName == null) {
			overrides.preconfirmSoundName = DEFAULT_CONFIG.preconfirmSoundName;
		}
	}
	if (flags.preconfirmSoundName != null) {
		overrides.preconfirmSoundName = flags.preconfirmSoundName;
	}
	if (readyOverlayEnabled != null) {
		overrides.readyOverlayEnabled = readyOverlayEnabled;
	}
	if (reviewWindowSeconds != null) {
		overrides.reviewWindowSeconds = reviewWindowSeconds;
	}
	if (flags.asrApiUrl != null) {
		overrides.asrApiUrl = flags.asrApiUrl;
	}
	if (flags.asrModel != null) {
		overrides.asrModel = flags.asrModel;
	}
	if (flags.asrApiKeyEnv != null) {
		overrides.asrApiKeyEnv = flags.asrApiKeyEnv;
	}
	if (flags.asrLanguage != null) {
		overrides.asrLanguage = flags.asrLanguage;
	}
	if (flags.asrPrompt != null) {
		overrides.asrPrompt = flags.asrPrompt;
	}
	const asrBackend = parseChoiceFlag(
		flags.asrBackend,
		'--asr-backend',
		['qwen-mlx', 'faster-whisper', 'whisper-cpp'],
	);
	if (asrBackend != null) {
		overrides.asrBackend = asrBackend;
	}
	if (flags.asrHost != null) {
		overrides.asrHost = flags.asrHost;
	}
	const asrPort = parsePositiveIntegerFlag(flags.asrPort, '--asr-port');
	if (asrPort != null) {
		if (asrPort > 65535) {
			throw new Error(`Invalid value for --asr-port: ${flags.asrPort}`);
		}
		overrides.asrPort = asrPort;
	}
	if (flags.asrDevice != null) {
		overrides.asrDevice = flags.asrDevice;
	}
	if (flags.asrComputeType != null) {
		overrides.asrComputeType = flags.asrComputeType;
	}
	const asrCpuThreads = parseNonNegativeIntegerFlag(flags.asrCpuThreads, '--asr-cpu-threads');
	if (asrCpuThreads != null) {
		overrides.asrCpuThreads = asrCpuThreads;
	}
	const asrBeamSize = parsePositiveIntegerFlag(flags.asrBeamSize, '--asr-beam-size');
	if (asrBeamSize != null) {
		overrides.asrBeamSize = asrBeamSize;
	}
	const asrBestOf = parsePositiveIntegerFlag(flags.asrBestOf, '--asr-best-of');
	if (asrBestOf != null) {
		overrides.asrBestOf = asrBestOf;
	}
	if (flags.whisperCppBin != null) {
		overrides.whisperCppBin = flags.whisperCppBin;
	}
	const whisperCppTimeout = parsePositiveNumberFlag(flags.whisperCppTimeout, '--whisper-cpp-timeout');
	if (whisperCppTimeout != null) {
		overrides.whisperCppTimeout = whisperCppTimeout;
	}
	if (flags.noVadFilter) {
		overrides.asrVadFilter = false;
	}
	if (flags.fakeTranscript != null) {
		overrides.fakeTranscript = flags.fakeTranscript;
	}
	if (flags.audioInputDeviceName != null) {
		overrides.audioInputDeviceName = flags.audioInputDeviceName;
	}
	if (flags.audioInputDeviceIndex != null) {
		overrides.audioInputDeviceIndex = flags.audioInputDeviceIndex;
	}
	const deliveryMode = parseChoiceFlag(
		flags.deliveryMode,
		'--delivery-mode',
		['paste_and_send', 'paste_only', 'clipboard_only'],
	);
	if (deliveryMode != null) {
		overrides.deliveryMode = deliveryMode;
	}
	return overrides;
}

async function askBooleanPrompt(message, initialValue) {
	const answer = await confirm({ message, initialValue });
	if (isCancel(answer)) {
		cancel('Cancelled');
		process.exit(1);
	}
	return answer;
}

async function askSelectPrompt(message, initialValue, options) {
	const answer = await select({
		message,
		initialValue,
		options,
	});
	if (isCancel(answer)) {
		cancel('Cancelled');
		process.exit(1);
	}
	return answer;
}

async function askTextPrompt(message, initialValue, validate) {
	const answer = await text({
		message,
		initialValue,
		validate,
	});
	if (isCancel(answer)) {
		cancel('Cancelled');
		process.exit(1);
	}
	return answer;
}

async function collectInteractiveConfig(runtime, overrides = {}) {
	const currentConfig = mergeConfig(await loadConfig(runtime), overrides);
	const audioInputDeviceName = await askTextPrompt(
		'Audio input device name',
		currentConfig.audioInputDeviceName,
		(value) =>
			!value?.trim() && !currentConfig.audioInputDeviceIndex
				? 'Enter a microphone name or use --input-device-index.'
				: undefined,
	);
	const modelOptions = [
		{ value: 'whisper-large-v3-turbo', label: 'Large v3 Turbo', hint: 'Best default for coding accuracy' },
		{ value: 'small', label: 'Small', hint: 'Lower download size and memory use' },
		{ value: 'tiny', label: 'Tiny', hint: 'Fast hardware and permission testing' },
	];
	if (process.arch === 'arm64') {
		modelOptions.unshift({ value: QWEN_MODEL, label: 'Qwen3-ASR 0.6B · 4-bit MLX', hint: 'Live transcription on Apple Silicon' });
	}
	if (!modelOptions.some((option) => option.value === currentConfig.asrModel)) {
		modelOptions.unshift({
			value: currentConfig.asrModel,
			label: currentConfig.asrModel,
			hint: 'Current custom model',
		});
	}
	const asrModel = await askSelectPrompt('Local transcription model', currentConfig.asrModel, modelOptions);
	const deliveryMode = await askSelectPrompt('After transcription', currentConfig.deliveryMode, [
		{ value: 'paste_and_send', label: 'Paste and submit', hint: 'Best for voice-driven coding agents' },
		{ value: 'paste_only', label: 'Paste only', hint: 'Review text before sending' },
		{ value: 'clipboard_only', label: 'Clipboard only', hint: 'Never inject keys into the active app' },
	]);
	const soundOptions = await listSystemSounds(runtime);
	const selectableSoundOptions = [
		{ value: '', label: 'Off' },
		...soundOptions.map((soundName) => ({ value: soundName, label: soundName })),
	];
	const currentPreconfirmSoundName = currentConfig.audioFeedbackEnabled ? currentConfig.preconfirmSoundName : '';
	const initialPreconfirmSound = soundOptions.includes(currentPreconfirmSoundName) ? currentPreconfirmSoundName : '';
	const preconfirmSoundName = await askSelectPrompt(
		buildPromptMessage(
			'Completion sound',
			`Default: ${formatSoundDefaultLabel(initialPreconfirmSound)}`,
		),
		initialPreconfirmSound,
		selectableSoundOptions,
	);
	const readyOverlayEnabled = await askBooleanPrompt('Show the recording and transcription HUD?', currentConfig.readyOverlayEnabled);
	return {
		audioInputDeviceName: audioInputDeviceName.trim(),
		asrModel,
		asrBackend: asrModel === QWEN_MODEL ? 'qwen-mlx' : ['whisper-large-v3-turbo', 'small', 'tiny'].includes(asrModel) ? 'faster-whisper' : currentConfig.asrBackend,
		deliveryMode,
		audioFeedbackEnabled: preconfirmSoundName !== '',
		preconfirmSoundName,
		readyOverlayEnabled,
	};
}

function formatSoundSetting(soundName) {
	return soundName ? soundName : 'off';
}

function printJson(result) {
	process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

function createProgress(enabled) {
	if (!enabled) {
		return {
			start() {},
			stop() {},
		};
	}
	return spinner();
}

function createCliError(message, code, cause) {
	const error = new Error(message);
	error.code = code;
	if (cause) {
		error.cause = cause;
	}
	return error;
}

async function pathExists(filePath) {
	try {
		await fs.access(filePath);
		return true;
	} catch {
		return false;
	}
}

function sleep(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForPath(filePath, timeoutMs) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (await pathExists(filePath)) {
			return true;
		}
		await sleep(FILE_WAIT_INTERVAL_MS);
	}
	return pathExists(filePath);
}

async function openApplication(appName) {
	try {
		await execFile('open', ['-a', appName]);
		return true;
	} catch {
		return false;
	}
}

async function openSettingsPanel(url) {
	try {
		await execFile('open', [url]);
		return true;
	} catch {
		return false;
	}
}

async function commandAvailable(command, args = ['--version']) {
	try {
		await execFile(command, args);
		return true;
	} catch {
		return false;
	}
}

function formatPermissionAction(item) {
	switch (item.key) {
		case 'karabinerInputMonitoring':
			return 'Input Monitoring: managed by the external Karabiner trigger driver';
		case 'accessibilityCurrentSession':
			return item.status === 'unknown'
				? 'Accessibility: SpeekCoding has not been authorized yet'
				: 'Accessibility: allow SpeekCoding';
		case 'postEventCurrentSession':
			return item.status === 'unknown'
				? 'Event control: SpeekCoding has not been authorized yet'
				: 'Event control: allow SpeekCoding to send paste and Return';
		case 'microphone':
			return ['unknown', 'not_determined'].includes(item.status)
				? 'Microphone: SpeekCoding has not requested access yet'
				: 'Microphone: allow SpeekCoding';
		default:
			return `${item.label}: ${item.status}`;
	}
}

function printPermissionsReminder(permissions) {
	if (!permissions || permissions.status === 'ok') {
		return;
	}
	const issues = getInstallPermissionReminderIssues(permissions);
	if (issues.length === 0) {
		return;
	}
	note(issues.map((item) => formatPermissionAction(item)).join('\n'), 'Permissions needing attention');
}

function formatDoctorReport(report) {
	const lines = [
		`installed: ${report.installed ? 'yes' : 'no'}`,
		`package version: ${report.packageVersion}`,
		`installed version: ${report.installedVersion || 'none'}`,
		`update available: ${report.updateAvailable ? 'yes' : 'no'}`,
		`distribution: ${report.packagedInstallation ? 'self-contained package' : 'source install'}`,
		`ASR Python: ${report.bundledPythonAvailable ? 'bundled' : report.venvPythonExists ? 'venv' : 'missing'}`,
		`Karabiner CLI: ${report.karabinerCliExists ? 'ok' : 'missing'}`,
		`Karabiner config: ${report.karabinerConfigExists ? 'ok' : 'missing'}`,
		`SpeekCoding.app: ${report.speekCodingAppInstalled ? 'installed' : 'missing'}`,
		`App signature: ${report.appSignature?.status || 'unknown'}`,
		`App IPC: ${report.agent?.running ? 'ready' : 'not running'}`,
		`ASR server installed: ${report.asrServerInstalled ? 'yes' : 'no'}`,
		`HUD installed: ${report.hudInstalled ? 'yes' : 'no'}`,
		`audio runtime: ${report.audioRuntime?.status || 'unknown'}`,
		`config installed: ${report.configInstalled ? 'yes' : 'no'}`,
		`trigger mode: ${formatTriggerMode(report.triggerMode)}`,
		`device: ${report.connectedDevice.status}`,
		`managed profiles: ${report.managedProfiles.length ? report.managedProfiles.map((profile) => profile.name).join(', ') : 'none'}`,
	];
	if (!report.packagedInstallation) {
		lines.splice(6, 0, `developer python3: ${report.pythonAvailable ? 'ok' : 'missing'}`);
		lines.splice(7, 0, `developer swiftc: ${report.swiftcAvailable ? 'ok' : 'missing'}`);
	}
	if (report.permissions?.status) {
		lines.push(`permissions: ${report.permissions.status}`);
	}
	return lines.join('\n');
}

function formatStatusReport(report, service) {
	const workflowHealthy =
		report.installed &&
		!report.updateAvailable &&
		report.profileCurrent &&
		report.audioRuntime?.status === 'ok' &&
		report.appSignature?.status === 'ok' &&
		report.agent?.running;
	const serviceState = service.bypassed
		? 'test mode (fixed transcript)'
		: service.health.ok
			? 'ready'
			: service.loaded
				? 'starting or unavailable'
				: 'stopped';
	const nextAction = !report.installed
		? 'Run `speek setup`'
		: report.updateAvailable || !report.profileCurrent
			? 'Run `speek update`'
		: !service.health.ok && !service.bypassed
				? 'Run `speek restart`, then `speek logs` if it stays unavailable'
				: 'Press Fn or the configured DJI Mic Mini button to dictate';
	return [
		`Speek ${report.packageVersion}`,
		`workflow: ${workflowHealthy ? 'ready' : 'needs attention'}`,
		`ASR: ${serviceState}`,
		`startup: ${service.startsAtLogin ? 'at login' : service.loaded ? 'current login session' : 'not loaded'}`,
		`trigger: ${formatTriggerMode(report.triggerMode)}`,
		`audio runtime: ${report.audioRuntime?.status || 'unknown'}`,
		`permissions: ${report.permissions?.status || 'unknown'}`,
		`next: ${nextAction}`,
	].join('\n');
}

async function readRecentLog(filePath, lineCount) {
	try {
		const content = await fs.readFile(filePath, 'utf-8');
		return content.split(/\r?\n/u).slice(-lineCount).join('\n').trim();
	} catch (error) {
		if (error.code === 'ENOENT') {
			return '';
		}
		throw error;
	}
}

async function showServiceLogs(runtime, flags) {
	const lineCount = parsePositiveIntegerFlag(flags.lines ?? 80, '--lines');
	const paths = [runtime.asrStdoutLogPath, runtime.asrStderrLogPath];
	if (flags.follow) {
		const code = await new Promise((resolve, reject) => {
			const child = spawn('/usr/bin/tail', ['-n', String(lineCount), '-F', ...paths], { stdio: 'inherit' });
			child.on('error', reject);
			child.on('close', resolve);
		});
		return { paths, following: true, code };
	}
	const [stdout, stderr] = await Promise.all(paths.map((filePath) => readRecentLog(filePath, lineCount)));
	return { paths, following: false, stdout, stderr };
}

async function collectInteractiveTriggerMode(runtime) {
	const manifest = await readManifest(runtime);
	if (manifest?.triggerMode) {
		return { triggerMode: manifest.triggerMode, reusedTriggerMode: manifest.triggerMode };
	}

	const installReport = await doctor(runtime);
	if (installReport.installed && installReport.managedProfiles.length > 0) {
		return { triggerMode: installReport.triggerMode, reusedTriggerMode: installReport.triggerMode };
	}

	const detectedDevice = await detectOptionalTriggerDevice(runtime);
	if (detectedDevice.status === 'connected') {
		note(
			['DJI Mic Mini receiver detected', 'Optional trigger will be enabled'].join('\n'),
			'Trigger mode',
		);
		return { triggerMode: 'keyboard+dji', reusedTriggerMode: null };
	}

	const triggerMode = await select({
		message:
			detectedDevice.status === 'unknown'
				? 'Could not confirm whether a DJI Mic Mini is connected. Install keyboard workflow only, or also configure the optional DJI trigger?'
				: 'No DJI Mic Mini detected right now. Install keyboard workflow only, or also configure the optional DJI trigger for later?',
		initialValue: 'keyboard',
		options: [
			{
				value: 'keyboard',
				label: 'Keyboard workflow only',
				hint: 'Fn stays first-class; no external button required',
			},
			{
				value: 'keyboard+dji',
				label: 'Keyboard workflow + DJI Mic Mini trigger',
				hint: 'Adds an optional hardware trigger mapped to the same workflow',
			},
		],
	});
	if (isCancel(triggerMode)) {
		cancel('Cancelled');
		process.exit(1);
	}
	return { triggerMode, reusedTriggerMode: null };
}

async function collectInteractiveProfileOptions(runtime) {
	const profiles = await getKarabinerProfiles(runtime);
	const manifest = await readManifest(runtime);
	const promptPlan = buildInstallProfilePromptPlan({ profiles, manifest });
	const activeProfile = profiles.find((profile) => profile.selected) || profiles[0];

	if (promptPlan.kind === 'reuse-installed') {
		return { profileOptions: promptPlan.profileOptions, reusedProfileName: promptPlan.profileName };
	}

	if (promptPlan.kind === 'single-profile') {
		const mode = await select({
			message: `Detected one Karabiner profile: ${promptPlan.currentProfileName}`,
			initialValue: 'active',
			options: [
				{
					value: 'active',
					label: 'Use current profile',
					hint: promptPlan.currentProfileName,
				},
				{ value: 'clone', label: 'Clone current profile into a dedicated profile' },
			],
		});
		if (isCancel(mode)) {
			cancel('Cancelled');
			process.exit(1);
		}
		if (mode === 'active') {
			return { profileOptions: promptPlan.profileOptions, reusedProfileName: null };
		}
		const newProfileName = await askTextPrompt(
			'Name for the dedicated Karabiner profile',
			promptPlan.defaultCloneName,
			(value) => {
				if (!value?.trim()) {
					return 'Profile name is required.';
				}
				if (profiles.some((profile) => profile.name === value.trim())) {
					return 'That Karabiner profile already exists.';
				}
				return undefined;
			},
		);
		return {
			profileOptions: {
				profileStrategy: 'clone',
				sourceProfileName: promptPlan.currentProfileName,
				newProfileName: newProfileName.trim(),
			},
			reusedProfileName: null,
		};
	}

	const mode = await select({
		message: 'Choose how to handle the Karabiner profile',
		initialValue: activeProfile ? 'active' : 'existing',
		options: [
			{
				value: 'active',
				label: 'Use current active profile',
				hint: activeProfile ? activeProfile.name : 'first profile',
			},
			{ value: 'existing', label: 'Use an existing profile' },
			{ value: 'clone', label: 'Clone an existing profile into a dedicated profile' },
		],
	});
	if (isCancel(mode)) {
		cancel('Cancelled');
		process.exit(1);
	}

	if (mode === 'active') {
		return { profileOptions: { profileStrategy: 'active' }, reusedProfileName: null };
	}

	const selectedSource = await select({
		message: mode === 'existing' ? 'Choose the Karabiner profile to use' : 'Choose the Karabiner profile to clone',
		initialValue: activeProfile?.name,
		options: profiles.map((profile) => ({
			value: profile.name,
			label: profile.name,
			hint: profile.selected ? 'active' : undefined,
		})),
	});
	if (isCancel(selectedSource)) {
		cancel('Cancelled');
		process.exit(1);
	}

	if (mode === 'existing') {
		return {
			profileOptions: { profileStrategy: 'existing', profileName: selectedSource },
			reusedProfileName: null,
		};
	}

	const newProfileName = await askTextPrompt(
		'Name for the dedicated Karabiner profile',
		`${selectedSource} - Speek Coding`,
		(value) => {
			if (!value?.trim()) {
				return 'Profile name is required.';
			}
			if (profiles.some((profile) => profile.name === value.trim())) {
				return 'That Karabiner profile already exists.';
			}
			return undefined;
		},
	);

	return {
		profileOptions: {
			profileStrategy: 'clone',
			sourceProfileName: selectedSource,
			newProfileName: newProfileName.trim(),
		},
		reusedProfileName: null,
	};
}

async function brewInstallKarabiner(showUi) {
	const brewArgs = ['install', '--cask', 'karabiner-elements'];
	if (showUi) {
		note('Running: brew install --cask karabiner-elements\n(this may take a few minutes and ask for your password)', 'Homebrew');
		const code = await new Promise((resolve, reject) => {
			const child = spawn('brew', brewArgs, { stdio: 'inherit' });
			child.on('error', reject);
			child.on('close', resolve);
		});
		if (code !== 0) {
			throw createCliError(
				`brew install exited with code ${code}`,
				'KARABINER_INSTALL_FAILED',
			);
		}
		log.success('Karabiner-Elements installed');
	} else {
		try {
			await execFile('brew', brewArgs);
		} catch (error) {
			const detail = [error.stderr, error.stdout, error.message]
				.map((value) => value?.trim())
				.find(Boolean);
			throw createCliError(
				`Failed to install Karabiner-Elements via Homebrew${detail ? `: ${detail}` : '.'}`,
				'KARABINER_INSTALL_FAILED',
				error,
			);
		}
	}
}

async function waitForManualKarabinerInstall(runtime) {
	note(
		`Download and install Karabiner-Elements from:\n${KARABINER_DOWNLOAD_URL}`,
		'Karabiner setup',
	);
	await openSettingsPanel(KARABINER_DOWNLOAD_URL);
	while (!(await pathExists(runtime.karabinerCliPath))) {
		const shouldRetry = await askBooleanPrompt('Check again after installing Karabiner-Elements?', true);
		if (!shouldRetry) {
			cancel('Install paused until Karabiner-Elements is installed.');
			process.exit(1);
		}
	}
}

async function ensureKarabinerConfigReady(runtime, interactive) {
	if (await pathExists(runtime.karabinerConfigPath)) {
		return;
	}

	await openApplication(KARABINER_APP_NAME);
	if (await waitForPath(runtime.karabinerConfigPath, KARABINER_READY_TIMEOUT_MS)) {
		return;
	}

	const errorMessage = `Karabiner-Elements is installed, but ${runtime.karabinerConfigPath} was not created. Open Karabiner-Elements once, then rerun install.`;
	if (!interactive) {
		throw createCliError(errorMessage, 'KARABINER_CONFIG_NOT_READY');
	}

	note(
		'Karabiner-Elements must be opened once before install can continue.',
		'Karabiner setup',
	);
	while (true) {
		await openApplication(KARABINER_APP_NAME);
		const shouldRetry = await askBooleanPrompt('Open Karabiner-Elements, then check again?', true);
		if (!shouldRetry) {
			cancel('Install paused until Karabiner-Elements has created its config file.');
			process.exit(1);
		}
		if (await waitForPath(runtime.karabinerConfigPath, KARABINER_RECHECK_TIMEOUT_MS)) {
			return;
		}
		note('Karabiner config file still not found. Open Karabiner-Elements once, then try again.', 'Not ready');
	}
}

async function ensureKarabinerInstalled(runtime, flags, interactive) {
	const karabinerCliExists = await pathExists(runtime.karabinerCliPath);
	if (!karabinerCliExists) {
		const brewAvailable = await commandAvailable('brew');
		if (interactive && !flags.yes) {
			note(
				'Karabiner-Elements is required to install this workflow.',
				'Missing dependency',
			);
			if (brewAvailable) {
				const shouldInstall = await askBooleanPrompt(
					'Install Karabiner-Elements with Homebrew now?',
					true,
				);
				if (shouldInstall) {
					await brewInstallKarabiner(true);
				} else {
					await waitForManualKarabinerInstall(runtime);
				}
			} else {
				await waitForManualKarabinerInstall(runtime);
			}
		} else if (brewAvailable) {
			await brewInstallKarabiner(interactive);
		} else {
			throw createCliError(
				`Karabiner-Elements is required. Install it from ${KARABINER_DOWNLOAD_URL}, open it once, then rerun setup.`,
				'KARABINER_MISSING',
			);
		}
	}

	await ensureKarabinerConfigReady(runtime, interactive);
}

async function openPermissionPanels(issues) {
	const issueKeys = new Set(issues.map((item) => item.key));
	if (issueKeys.has('karabinerInputMonitoring')) {
		await openSettingsPanel(INPUT_MONITORING_SETTINGS_URL);
	}
	if (issueKeys.has('accessibilityCurrentSession') || issueKeys.has('postEventCurrentSession')) {
		await openSettingsPanel(ACCESSIBILITY_SETTINGS_URL);
	}
	if (issueKeys.has('microphone')) {
		await openSettingsPanel(MICROPHONE_SETTINGS_URL);
	}
}

async function ensurePermissionsInteractive(runtime, initialPermissions) {
	let permissions = initialPermissions;
	if (!permissions || permissions.status !== 'ok') {
		permissions = await requestPermissions(runtime);
	}
	while (true) {
		permissions ??= await detectPermissions(runtime);
		const issues = getBlockingPermissionIssues(permissions);
		if (issues.length === 0) {
			return permissions;
		}

		note(
			issues.map((item) => formatPermissionAction(item)).join('\n'),
			'Permissions needing attention',
		);

		await openPermissionPanels(issues);

		const retry = await askBooleanPrompt('Check permissions again after updating System Settings?', true);
		if (!retry) {
			cancel('Install paused until the required permissions are granted.');
			process.exit(1);
		}
		permissions = null;
	}
}

async function retryableInstall(runtime, flags, interactive) {
	const showUi = interactive;
	let configOverrides = buildConfigOverrides(flags);
	const explicitProfileOverrides = buildProfileOverrides(flags);
	const explicitTriggerMode = flags.triggerMode;

	await ensureKarabinerInstalled(runtime, flags, interactive);

	while (true) {
		const s = createProgress(showUi);
		try {
			let profileOptions = explicitProfileOverrides;
			let triggerMode = explicitTriggerMode;
			let reusedProfileName = null;
			let reusedTriggerMode = null;
			if (showUi && !explicitProfileOverrides) {
				const profileDecision = await collectInteractiveProfileOptions(runtime);
				profileOptions = profileDecision.profileOptions;
				reusedProfileName = profileDecision.reusedProfileName;
			}
			if (showUi && !explicitTriggerMode) {
				const triggerDecision = await collectInteractiveTriggerMode(runtime);
				triggerMode = triggerDecision.triggerMode;
				reusedTriggerMode = triggerDecision.reusedTriggerMode;
			}
			if (showUi && (reusedProfileName || reusedTriggerMode)) {
				printExistingInstallSummary({
					profileName: reusedProfileName,
					triggerMode: reusedTriggerMode,
				});
			}
			if (showUi && Object.keys(configOverrides).length === 0) {
				configOverrides = await collectInteractiveConfig(runtime);
			}
			s.start('Applying Karabiner, script, and config changes');
			const result = await install(runtime, {
				profileOptions,
				triggerMode,
				configOverrides,
			});
			s.stop(`Installed on profile ${result.profileName}`);
			if (showUi && result.profileSwitch.status === 'failed') {
				note(
					`Karabiner CLI could not switch to profile "${result.profileName}" automatically. Select it manually in Karabiner-Elements if needed.`,
					'Profile switch warning',
				);
			}
			if (showUi) {
				result.permissions = await ensurePermissionsInteractive(runtime, result.permissions);
			} else if (!flags.json) {
				printPermissionsReminder(result.permissions);
			}
			if (showUi && result.triggerMode === 'keyboard+dji' && result.device.status !== 'connected') {
				note('DJI receiver not detected right now. You can still finish setup and run `doctor` later.', 'Device check');
			}
			return result;
		} catch (error) {
			s.stop('Install failed');
			if (!showUi || flags.yes || !['KARABINER_CONFIG_MISSING'].includes(error.code)) {
				throw error;
			}
			note(error.message, 'Action required');
			const shouldRetry = await askBooleanPrompt('Retry install after fixing this?', true);
			if (!shouldRetry) {
				throw error;
			}
		}
	}
}

async function runAsrServer(runtime, flags) {
	const config = await loadConfig(runtime);
	const pythonBin = config.pythonBin || `${runtime.venvDir}/bin/python`;
	const serverPath = (await pathExists(runtime.asrServerTargetPath))
		? runtime.asrServerTargetPath
		: runtime.asrServerSourcePath;
	if (!(await pathExists(pythonBin))) {
		throw createCliError(`Python venv not found at ${pythonBin}. Run asr-install first.`, 'PYTHON_VENV_MISSING');
	}
	if (!(await pathExists(serverPath))) {
		throw createCliError(`ASR server script not found at ${serverPath}. Run asr-install first.`, 'ASR_SERVER_MISSING');
	}

	const args = [
		serverPath,
		'--host',
		flags.asrHost || config.asrHost,
		'--port',
		String(flags.asrPort || config.asrPort),
		'--backend',
		flags.asrBackend || config.asrBackend,
		'--model',
		flags.asrModel || config.asrModel,
		'--device',
		flags.asrDevice || config.asrDevice,
		'--compute-type',
		flags.asrComputeType || config.asrComputeType,
		'--cpu-threads',
		String(flags.asrCpuThreads ?? config.asrCpuThreads),
		'--beam-size',
		String(flags.asrBeamSize || config.asrBeamSize),
	];
	args.push('--best-of', String(flags.asrBestOf || config.asrBestOf));
	args.push('--whisper-cpp-timeout', String(flags.whisperCppTimeout || config.whisperCppTimeout));
	if (flags.whisperCppBin != null || config.whisperCppBin) {
		args.push('--whisper-cpp-bin', flags.whisperCppBin || config.whisperCppBin);
	}
	if (flags.noVadFilter || !config.asrVadFilter) {
		args.push('--no-vad-filter');
	}
	if (config.asrQuiet) {
		args.push('--quiet');
	}
	const code = await new Promise((resolve, reject) => {
		const child = spawn(pythonBin, ['-B', ...args], { stdio: 'inherit' });
		child.on('error', reject);
		child.on('close', resolve);
	});
	if (code !== 0) {
		throw createCliError(`ASR server exited with code ${code}`, 'ASR_SERVER_FAILED');
	}
	return { code };
}

async function run() {
	const runtime = createRuntime();
	const argv = process.argv.slice(2);
	let command;
	let flags;
	try {
		({ command, flags } = parseArgs(argv));
	} catch (error) {
		if (argv.includes('--json')) {
			printJson({ ok: false, error: error.message, code: 'INVALID_ARGUMENT' });
		} else {
			cancel(error.message);
		}
		process.exitCode = 1;
		return;
	}
	const canonicalCommand = command === 'configure' ? 'config' : command;
	const interactive = Boolean(process.stdin.isTTY && process.stdout.isTTY && !flags.json);

	if (flags.version) {
		process.stdout.write(`${runtime.packageVersion}\n`);
		return;
	}

	if (flags.help || canonicalCommand === 'help') {
		process.stdout.write(HELP_TEXT);
		return;
	}

	if (interactive) {
		intro(`Speek · ${command}`);
	}

	let result;
	try {
		const profileOverrides = buildProfileOverrides(flags);
		switch (canonicalCommand) {
			case 'setup': {
				const installation = await retryableInstall(runtime, flags, interactive);
				result = { installation, asr: null, service: null };
				if (!flags.skipAsr) {
					const s = createProgress(interactive);
					s.start('Installing the private local transcription runtime');
					result.asr = await installAsrRuntime(runtime);
					s.stop('Local transcription runtime installed');
					if (!flags.noStart) {
						const serviceSpinner = createProgress(interactive);
						serviceSpinner.start('Starting Speek in the background');
						result.service = await installAsrService(runtime);
						serviceSpinner.stop('Speek is running in the background');
					}
				}
				break;
			}
			case 'install':
				result = await retryableInstall(runtime, flags, interactive);
				break;
			case 'update': {
				const s = createProgress(interactive);
				s.start('Updating installed files and Karabiner rules');
				result = await update(runtime, {
					profileOptions: profileOverrides || undefined,
					triggerMode: flags.triggerMode,
					configOverrides: buildConfigOverrides(flags),
				});
				s.stop(`Updated installation on profile ${result.profileName}`);
				if (interactive && result.appCleanup?.warnings.length) {
					note(result.appCleanup.warnings.join('\n'), 'Old app cleanup warnings');
				}
				if (interactive && result.profileSwitch.status === 'failed') {
					note(
						`Karabiner CLI could not switch to profile "${result.profileName}" automatically. Select it manually in Karabiner-Elements if needed.`,
						'Profile switch warning',
					);
				}
				break;
			}
			case 'doctor': {
				const s = createProgress(interactive);
				s.start('Inspecting current setup');
				result = await doctor(runtime);
				s.stop('Doctor report ready');
				break;
			}
			case 'status': {
				const s = createProgress(interactive);
				s.start('Checking Speek');
				const [report, service] = await Promise.all([
					doctor(runtime),
					getAsrServiceStatus(runtime),
				]);
				result = { report, service };
				s.stop('Status ready');
				break;
			}
			case 'start': {
				const s = createProgress(interactive);
				s.start('Starting local transcription');
				result = await startAsrService(runtime);
				s.stop('Local transcription started');
				break;
			}
			case 'stop': {
				const s = createProgress(interactive);
				s.start('Stopping local transcription');
				result = await stopAsrService(runtime);
				s.stop('Local transcription stopped');
				break;
			}
			case 'restart': {
				const s = createProgress(interactive);
				s.start('Reloading local transcription configuration');
				result = await restartAsrService(runtime);
				s.stop('Local transcription restarted');
				break;
			}
			case 'logs':
				result = await showServiceLogs(runtime, flags);
				break;
			case 'trigger':
				result = await sendAgentCommand(runtime, { command: 'toggle', source: 'cli' });
				break;
			case 'cancel':
				result = await sendAgentCommand(runtime, { command: 'cancel', source: 'cli' });
				break;
			case 'permissions':
				result = await requestPermissions(runtime);
				break;
			case 'config': {
				let configOverrides = buildConfigOverrides(flags);
				if (interactive && Object.keys(configOverrides).length === 0) {
					configOverrides = await collectInteractiveConfig(runtime);
				}
				result = await configureInstallation(runtime, configOverrides);
				break;
			}
			case 'asr-install': {
				const s = createProgress(interactive);
				s.start('Installing local ASR dependencies');
				result = await installAsrRuntime(runtime);
				s.stop('Local ASR dependencies installed');
				break;
			}
			case 'asr-server': {
				result = await runAsrServer(runtime, flags);
				break;
			}
			case 'test-record': {
				const s = createProgress(interactive);
				s.start('Recording a short WAV');
				result = await testRecord(runtime, {
					durationSeconds: flags.duration == null ? 2 : parsePositiveNumberFlag(flags.duration, '--duration'),
					wavPath: flags.wavPath,
				});
				s.stop(`Recorded ${result.bytes} bytes`);
				break;
			}
			case 'uninstall': {
				if (interactive && !flags.yes) {
					const approved = await askBooleanPrompt('Remove the installed script, config, and Karabiner entries?', false);
					if (!approved) {
						cancel('Uninstall cancelled');
						return;
					}
				}
				result = await uninstall(runtime);
				break;
			}
			default:
				throw new Error(`Unknown command: ${command}`);
		}
	} catch (error) {
		if (flags.json) {
			printJson({ ok: false, error: error.message, code: error.code || null });
		} else {
			cancel(error.message);
		}
		process.exitCode = 1;
		return;
	}

	if (flags.json) {
		printJson({ ok: true, command: canonicalCommand, result });
		return;
	}

	if (canonicalCommand === 'status') {
		note(formatStatusReport(result.report, result.service), 'Speek status');
	} else if (canonicalCommand === 'doctor') {
		note(formatDoctorReport(result), 'Doctor summary');
	} else if (canonicalCommand === 'setup') {
		note(
			[
				`profile: ${result.installation.profileName}`,
				`trigger: ${formatTriggerMode(result.installation.triggerMode)}`,
				`local ASR: ${result.asr ? (result.service ? 'running' : 'installed') : 'skipped'}`,
				'next: press Fn once to record, then press it again to transcribe',
			].join('\n'),
			'Speek is ready',
		);
	} else if (['start', 'restart'].includes(canonicalCommand)) {
		note(
			[
				`service: ${result.loaded ? 'loaded' : 'starting'}`,
				`health: ${result.bypassed ? 'fixed transcript mode' : result.health.ok ? 'ready' : result.health.error}`,
				`logs: ${result.stderrLogPath}`,
			].join('\n'),
			'Local transcription',
		);
	} else if (canonicalCommand === 'stop') {
		note('The background ASR service is stopped. Run `speek start` to resume.', 'Local transcription');
	} else if (canonicalCommand === 'logs') {
		if (!result.following) {
			note(result.stdout || 'No standard output yet.', result.paths[0]);
			note(result.stderr || 'No errors logged.', result.paths[1]);
		}
	} else if (canonicalCommand === 'trigger' || canonicalCommand === 'cancel') {
		note(`state: ${result.state || result.result?.state || 'updated'}`, 'SpeekCoding');
	} else if (canonicalCommand === 'permissions') {
		note(
			(result.items || []).map((item) => `${item.label}: ${item.status}`).join('\n') || `status: ${result.status}`,
			'SpeekCoding permissions',
		);
	} else if (canonicalCommand === 'config') {
		note(
			[
				`input: ${result.audioInputDeviceIndex || result.audioInputDeviceName || 'system default'}`,
				`model: ${result.asrModel}`,
				`delivery: ${result.deliveryMode}`,
				`completion sound: ${formatSoundSetting(result.preconfirmSoundName)}`,
				`recording HUD: ${result.readyOverlayEnabled ? 'on' : 'off'}`,
				`fake transcript: ${result.fakeTranscript || 'off'}`,
			].join('\n'),
			'Configuration updated',
		);
	} else if (canonicalCommand === 'asr-install') {
		note(
			[
				`python: ${result.pythonBin}`,
				`server: ${result.asrServerPath}`,
				`package: ${result.package}`,
			].join('\n'),
			'Local ASR installed',
		);
	} else if (canonicalCommand === 'asr-server') {
		note(`exit code: ${result.code}`, 'Local ASR server stopped');
	} else if (canonicalCommand === 'test-record') {
		note(
			[
				`wav: ${result.wavPath}`,
				`duration: ${result.durationSeconds}s`,
				`bytes: ${result.bytes}`,
				`input: ${result.audioInputDeviceIndex || result.audioInputDeviceName || 'system default'}`,
			].join('\n'),
			'Recording test complete',
		);
	} else if (canonicalCommand === 'uninstall') {
		note(
			[`removed rules: ${result.removedRuleCount}`, `removed devices: ${result.removedDeviceCount}`].join('\n'),
			'Uninstall complete',
		);
	} else {
		const manifest = await readManifest(runtime);
		note(
			[
				`profile: ${result.profileName}`,
				`trigger mode: ${formatTriggerMode(result.triggerMode)}`,
				`app: ${manifest?.speekCodingAppTargetPath || runtime.speekCodingAppTargetPath}`,
				`version: ${runtime.packageVersion}`,
			].join('\n'),
			canonicalCommand === 'install' ? 'Install complete' : 'Update complete',
		);
	}

	if (interactive) {
		outro('Done');
	}
}

await run();
