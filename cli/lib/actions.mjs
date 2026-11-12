import { constants as fsConstants } from 'node:fs';
import { execFile as execFileCallback } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

import { DEFAULT_CONFIG, QWEN_MODEL, loadConfig, normalizeConfig, writeConfig } from './config.mjs';
import {
	findManagedEntries,
	findProfile,
	inferTriggerMode,
	isManagedRuleCurrent,
	listProfiles,
	loadKarabinerConfig,
	loadRuleTemplate,
	MANAGED_DEVICE,
	removeManagedEntries,
	resolveTargetProfile,
	syncManagedEntries,
	TRIGGER_MODE_KEYBOARD,
	TRIGGER_MODE_KEYBOARD_DJI,
	writeKarabinerConfig,
} from './karabiner.mjs';
import { detectPermissions } from './permissions.mjs';
import { filterInstallPermissionReport } from './install-permissions.mjs';
import { uninstallAsrService } from './service.mjs';
import { getAgentStatus, sendAgentCommand } from './agent.mjs';

const execFile = promisify(execFileCallback);
const MANIFEST_VERSION = 2;

async function pathExists(filePath) {
	try {
		await fs.access(filePath, fsConstants.F_OK);
		return true;
	} catch {
		return false;
	}
}

async function removeIfExists(filePath) {
	try {
		await fs.rm(filePath, { force: true, recursive: false });
	} catch (error) {
		if (error.code !== 'ENOENT') {
			throw error;
		}
	}
}

async function removeOwnedDirectory(directoryPath, expectedUserID) {
	try {
		const metadata = await fs.lstat(directoryPath);
		if (metadata.isSymbolicLink() || !metadata.isDirectory() || metadata.uid !== Number(expectedUserID)) {
			throw createCommandError(
				`Refusing to remove an unsafe SpeekCoding state directory: ${directoryPath}.`,
				'UNSAFE_STATE_DIRECTORY',
			);
		}
		await fs.rm(directoryPath, { recursive: true, force: true });
	} catch (error) {
		if (error.code !== 'ENOENT') throw error;
	}
}

async function ensureIPCToken(runtime) {
	await fs.mkdir(runtime.configDir, { recursive: true, mode: 0o700 });
	await fs.chmod(runtime.configDir, 0o700);
	try {
		const existing = (await fs.readFile(runtime.ipcTokenPath, 'utf-8')).trim();
		if (!/^[a-f0-9]{64}$/u.test(existing)) {
			throw createCommandError('The SpeekCoding IPC credential is invalid.', 'IPC_CREDENTIAL_INVALID');
		}
		await fs.chmod(runtime.ipcTokenPath, 0o600);
		return existing;
	} catch (error) {
		if (error.code !== 'ENOENT') throw error;
	}
	const token = randomBytes(32).toString('hex');
	try {
		await fs.writeFile(runtime.ipcTokenPath, `${token}\n`, { encoding: 'utf-8', flag: 'wx', mode: 0o600 });
	} catch (error) {
		if (error.code === 'EEXIST') return ensureIPCToken(runtime);
		throw error;
	}
	return token;
}

async function shutdownAgentAtSocket(runtime, agentSocketPath, { strict = true } = {}) {
	const socketRuntime = { ...runtime, agentSocketPath };
	const status = await getAgentStatus(socketRuntime, { launch: false });
	if (!status.running) {
		if (strict && (await pathExists(agentSocketPath))) {
			throw createCommandError(
				`Refusing to replace an unverified IPC peer at ${agentSocketPath}.`,
				'AGENT_SOCKET_UNVERIFIED',
			);
		}
		return;
	}
	await sendAgentCommand(socketRuntime, { command: 'shutdown' }, { launch: false, timeoutMs: 2000 });
	const processIdentifier = Number(status.response?.pid);
	const processIsRunning = () => {
		if (!Number.isInteger(processIdentifier) || processIdentifier <= 0) return false;
		try {
			process.kill(processIdentifier, 0);
			return true;
		} catch (error) {
			return error.code !== 'ESRCH';
		}
	};
	const deadline = Date.now() + 5000;
	while (Date.now() < deadline && ((await pathExists(agentSocketPath)) || processIsRunning())) {
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	if ((await pathExists(agentSocketPath)) || processIsRunning()) {
		throw createCommandError(
			`SpeekCoding did not stop cleanly at ${agentSocketPath}.`,
			'AGENT_SHUTDOWN_TIMEOUT',
		);
	}
}

function createCommandError(message, code) {
	const error = new Error(message);
	error.code = code;
	return error;
}

function extractDesignatedRequirement(result) {
	const output = [result.stdout, result.stderr].filter(Boolean).join('\n');
	return (
		output
			.split(/\r?\n/u)
			.map((line) => line.trim())
			.find((line) => line.startsWith('designated =>')) || output.trim()
	);
}

async function readDesignatedRequirement(runtime, appPath) {
	const result = await execFile(runtime.codesignPath, ['-d', '-r-', appPath], { env: runtime.env });
	return extractDesignatedRequirement(result);
}

async function commandWorks(command, args = ['--version']) {
	try {
		await execFile(command, args);
		return true;
	} catch {
		return false;
	}
}

async function assertCommandWorks(command, args, message, code) {
	if (!(await commandWorks(command, args))) {
		throw createCommandError(message, code);
	}
}

async function assertInstallationPrerequisites(runtime) {
	if (!(await pathExists(runtime.karabinerConfigPath))) {
		throw createCommandError(
			`Karabiner config not found at ${runtime.karabinerConfigPath}. Open Karabiner-Elements once first.`,
			'KARABINER_CONFIG_MISSING',
		);
	}
}

async function assertSwiftCompiler(runtime) {
	await assertCommandWorks(
		runtime.swiftcPath,
		['--version'],
		`Swift compiler not found at ${runtime.swiftcPath}. Install Xcode Command Line Tools with: xcode-select --install`,
		'SWIFTC_MISSING',
	);
}

async function assertPython(runtime) {
	await assertCommandWorks(
		runtime.systemPythonPath,
		['--version'],
		`Python 3 not found. Install Python 3 or set PYTHON3_BIN before running Speek.`,
		'PYTHON3_MISSING',
	);
}

export async function readManifest(runtime) {
	try {
		return JSON.parse(await fs.readFile(runtime.manifestFilePath, 'utf-8'));
	} catch (error) {
		if (error.code === 'ENOENT') {
			return null;
		}
		throw error;
	}
}

async function writeManifest(runtime, manifest) {
	await fs.mkdir(runtime.configDir, { recursive: true, mode: 0o700 });
	await fs.chmod(runtime.configDir, 0o700);
	await fs.writeFile(runtime.manifestFilePath, `${JSON.stringify(manifest, null, 2)}\n`, {
		encoding: 'utf-8',
		mode: 0o600,
	});
	await fs.chmod(runtime.manifestFilePath, 0o600);
}

function isManagedDeviceIdentifiers(identifiers) {
	return (
		identifiers?.vendor_id === MANAGED_DEVICE.identifiers.vendor_id &&
		identifiers?.product_id === MANAGED_DEVICE.identifiers.product_id &&
		identifiers?.is_consumer === MANAGED_DEVICE.identifiers.is_consumer
	);
}

function parseConnectedDevicesJson(output) {
	try {
		const parsed = JSON.parse(output);
		return Array.isArray(parsed) ? parsed : null;
	} catch {
		return null;
	}
}

function hasManagedDeviceInCliOutput(stdout, stderr = '') {
	const parsedDevices = parseConnectedDevicesJson(stdout.trim());
	if (parsedDevices) {
		return parsedDevices.some((device) => isManagedDeviceIdentifiers(device?.device_identifiers));
	}

	const output = `${stdout}${stderr}`;
	return (
		new RegExp(`"?vendor_id"?\\s*[:=]\\s*${MANAGED_DEVICE.identifiers.vendor_id}`, 'u').test(output) &&
		new RegExp(`"?product_id"?\\s*[:=]\\s*${MANAGED_DEVICE.identifiers.product_id}`, 'u').test(output)
	);
}

export async function detectOptionalTriggerDevice(runtime) {
	if (!(await pathExists(runtime.karabinerCliPath))) {
		return { status: 'unknown', reason: 'karabiner_cli_missing' };
	}

	try {
		const { stdout, stderr } = await execFile(runtime.karabinerCliPath, ['--list-connected-devices'], {
			env: runtime.env,
		});
		const connected = hasManagedDeviceInCliOutput(stdout, stderr);
		return { status: connected ? 'connected' : 'not_connected', reason: null };
	} catch (error) {
		return {
			status: 'unknown',
			reason: error.code || 'karabiner_cli_failed',
		};
	}
}

function resolveConnectedDeviceStatus(triggerMode, detectedDevice) {
	if (triggerMode !== TRIGGER_MODE_KEYBOARD_DJI) {
		return { status: 'not_enabled', reason: 'optional_trigger_disabled' };
	}
	return detectedDevice;
}

async function selectProfileViaCli(runtime, profileName) {
	if (!(await pathExists(runtime.karabinerCliPath))) {
		return { status: 'skipped', reason: 'karabiner_cli_missing' };
	}

	try {
		await execFile(runtime.karabinerCliPath, ['--select-profile', profileName], {
			env: runtime.env,
		});
		return { status: 'selected', reason: null };
	} catch (error) {
		return { status: 'failed', reason: error.code || 'karabiner_cli_select_failed' };
	}
}

async function copyScript(runtime) {
	await fs.mkdir(runtime.karabinerScriptsDir, { recursive: true });
	await fs.copyFile(runtime.speekCommandSourcePath, runtime.speekCommandTargetPath);
	await fs.chmod(runtime.speekCommandTargetPath, 0o755);
	if (runtime.prebuiltHudPath && (await pathExists(runtime.prebuiltHudPath))) {
		await fs.copyFile(runtime.prebuiltHudPath, runtime.hudTargetPath);
	} else {
		await assertSwiftCompiler(runtime);
		await execFile(runtime.swiftcPath, [runtime.hudSourcePath, '-O', '-o', runtime.hudTargetPath], {
			env: runtime.env,
		});
	}
	await fs.chmod(runtime.hudTargetPath, 0o755);
	await fs.mkdir(runtime.configDir, { recursive: true });
	const app = await installSpeekCodingApp(runtime);
	await fs.copyFile(runtime.asrServerSourcePath, runtime.asrServerTargetPath);
	await fs.chmod(runtime.asrServerTargetPath, 0o755);
	return app;
}

async function installSpeekCodingApp(runtime) {
	if (
		runtime.prebuiltSpeekCodingAppPath &&
		path.resolve(runtime.prebuiltSpeekCodingAppPath) === path.resolve(runtime.speekCodingAppTargetPath)
	) {
		await execFile(runtime.codesignPath, ['--verify', '--deep', '--strict', runtime.speekCodingAppTargetPath], {
			env: runtime.env,
		});
		const designatedRequirement = await readDesignatedRequirement(runtime, runtime.speekCodingAppTargetPath);
		const launchServicesRegister =
			'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
		if (runtime.env.SPEEK_SKIP_LAUNCHSERVICES_REGISTER !== '1' && (await pathExists(launchServicesRegister))) {
			await execFile(launchServicesRegister, ['-f', runtime.speekCodingAppTargetPath], { env: runtime.env });
		}
		if (runtime.env.SPEEK_SKIP_AGENT_HEALTHCHECK !== '1') {
			await sendAgentCommand(runtime, { command: 'ping' }, { timeoutMs: 8000 });
		}
		return { signingIdentity: 'packaged-distribution', designatedRequirement };
	}

	await assertSwiftCompiler(runtime);
	const stagingPath = `${runtime.speekCodingAppTargetPath}.installing`;
	const backupPath = `${runtime.speekCodingAppTargetPath}.previous`;
	const appContentsDir = path.join(stagingPath, 'Contents');
	const macosDir = path.join(appContentsDir, 'MacOS');
	const executablePath = path.join(macosDir, 'SpeekCoding');
	await fs.rm(stagingPath, { recursive: true, force: true });
	await fs.mkdir(macosDir, { recursive: true });
	await execFile(
		runtime.swiftcPath,
		[
			runtime.speekCodingAppSourcePath,
			'-O',
			'-o',
			executablePath,
			'-framework',
			'AppKit',
			'-framework',
			'AVFoundation',
			'-framework',
			'ApplicationServices',
			'-framework',
			'CoreAudio',
			'-framework',
			'CoreGraphics',
		],
		{ env: runtime.env },
	);
	await fs.chmod(executablePath, 0o755);
	const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>zh-Hans</string>
		<string>zh-Hant</string>
	</array>
	<key>CFBundleExecutable</key>
	<string>SpeekCoding</string>
	<key>CFBundleIdentifier</key>
	<string>com.speek.coding</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>SpeekCoding</string>
	<key>CFBundleDisplayName</key>
	<string>SpeekCoding</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${runtime.packageVersion}</string>
	<key>CFBundleVersion</key>
	<string>${runtime.packageVersion}</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMultipleInstancesProhibited</key>
	<true/>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.speek.coding.command</string>
			<key>CFBundleURLSchemes</key>
			<array><string>speekcoding</string></array>
		</dict>
	</array>
	<key>NSMicrophoneUsageDescription</key>
	<string>SpeekCoding records audio only while you use push-to-talk dictation.</string>
</dict>
</plist>
`;
	await fs.writeFile(path.join(appContentsDir, 'Info.plist'), plist, 'utf-8');
	const resourceDirectory = path.join(appContentsDir, 'Resources');
	await fs.mkdir(resourceDirectory, { recursive: true });
	await fs.copyFile(path.join(runtime.repoRoot, 'licenses', 'LICENSES.txt'), path.join(resourceDirectory, 'OPEN_SOURCE_LICENSES.txt'));
	const entitlementsPath = path.join(appContentsDir, 'SpeekCoding.entitlements');
	await fs.writeFile(
		entitlementsPath,
		`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
`,
		'utf-8',
	);
	const { stdout: identityOutput } = await execFile(runtime.signingIdentityScriptPath, [], {
		env: runtime.env,
	});
	const signingIdentity = identityOutput.trim();
	if (!signingIdentity) {
		throw createCommandError('No stable SpeekCoding code-signing identity is available.', 'CODESIGN_IDENTITY_MISSING');
	}
	const previousManifest = await readManifest(runtime);
	if (
		previousManifest?.appSigningIdentity &&
		// This marker is not a certificate identity. Packaged-to-source updates
		// still verify both signatures and compare designated requirements below.
		previousManifest.appSigningIdentity !== 'packaged-distribution' &&
		previousManifest.appSigningIdentity !== signingIdentity
	) {
		throw createCommandError(
			`Refusing to replace SpeekCoding signing identity ${previousManifest.appSigningIdentity} with ${signingIdentity}.`,
			'CODESIGN_IDENTITY_CHANGED',
		);
	}
	await execFile(
		runtime.codesignPath,
		[
			'--force',
			'--deep',
			'--options',
			'runtime',
			'--sign',
			signingIdentity,
			'--identifier',
			'com.speek.coding',
			'--entitlements',
			entitlementsPath,
			stagingPath,
		],
		{ env: runtime.env },
	);
	await execFile(runtime.codesignPath, ['--verify', '--deep', '--strict', stagingPath], { env: runtime.env });
	const designatedRequirement = await readDesignatedRequirement(runtime, stagingPath);
	if (await pathExists(runtime.speekCodingAppTargetPath)) {
		await execFile(runtime.codesignPath, ['--verify', '--deep', '--strict', runtime.speekCodingAppTargetPath], {
			env: runtime.env,
		});
		const installedRequirement = await readDesignatedRequirement(runtime, runtime.speekCodingAppTargetPath);
		if (installedRequirement !== designatedRequirement) {
			throw createCommandError(
				`Refusing to replace SpeekCoding designated requirement ${installedRequirement} with ${designatedRequirement}.`,
				'CODESIGN_REQUIREMENT_CHANGED',
			);
		}
	}
	for (const socketPath of new Set([runtime.agentSocketPath, runtime.legacyAgentSocketPath])) {
		try {
			await shutdownAgentAtSocket(runtime, socketPath, { strict: socketPath === runtime.agentSocketPath });
		} catch (error) {
			if (['AGENT_SHUTDOWN_TIMEOUT', 'AGENT_SOCKET_UNVERIFIED'].includes(error.code)) throw error;
			// The app is not installed or this migration socket is not active.
		}
	}
	await fs.mkdir(path.dirname(runtime.speekCodingAppTargetPath), { recursive: true });
	await fs.rm(backupPath, { recursive: true, force: true });
	const hadInstalledApp = await pathExists(runtime.speekCodingAppTargetPath);
	if (hadInstalledApp) {
		await fs.rename(runtime.speekCodingAppTargetPath, backupPath);
	}
	try {
		await fs.rename(stagingPath, runtime.speekCodingAppTargetPath);
	} catch (error) {
		if (hadInstalledApp && (await pathExists(backupPath))) {
			await fs.rename(backupPath, runtime.speekCodingAppTargetPath);
		}
		throw error;
	}
	const launchServicesRegister =
		'/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
	const shouldRegisterWithLaunchServices =
		runtime.env.SPEEK_SKIP_LAUNCHSERVICES_REGISTER !== '1' && (await pathExists(launchServicesRegister));
	try {
		if (shouldRegisterWithLaunchServices) {
			await execFile(launchServicesRegister, ['-f', runtime.speekCodingAppTargetPath], { env: runtime.env });
		}
		if (runtime.env.SPEEK_SKIP_AGENT_HEALTHCHECK !== '1') {
			await sendAgentCommand(runtime, { command: 'ping' }, { timeoutMs: 8000 });
		}
	} catch (error) {
		try {
			await shutdownAgentAtSocket(runtime, runtime.agentSocketPath, { strict: false });
		} catch {
			// Continue with rollback when the failed candidate never opened its socket.
		}
		await fs.rm(runtime.speekCodingAppTargetPath, { recursive: true, force: true });
		if (hadInstalledApp && (await pathExists(backupPath))) {
			await fs.rename(backupPath, runtime.speekCodingAppTargetPath);
			if (shouldRegisterWithLaunchServices) {
				try {
					await execFile(launchServicesRegister, ['-f', runtime.speekCodingAppTargetPath], { env: runtime.env });
				} catch {
					// Preserve the restored App even if LaunchServices registration also fails.
				}
			}
		}
		throw createCommandError(
			`The new SpeekCoding.app failed registration or IPC health checks and was rolled back: ${error.message}`,
			'APP_HEALTHCHECK_FAILED',
		);
	}
	await fs.rm(backupPath, { recursive: true, force: true });
	return { signingIdentity, designatedRequirement };
}

async function bootstrapPythonEnv(runtime) {
	await assertPython(runtime);
	const python = runtime.systemPythonPath;
	const venvPython = `${runtime.venvDir}/bin/python`;
	if (!(await pathExists(venvPython))) {
		await fs.mkdir(runtime.configDir, { recursive: true });
		await execFile(python, ['-m', 'venv', runtime.venvDir], { env: runtime.env });
	}
	await execFile(venvPython, ['-m', 'pip', 'install', '--upgrade', 'pip', 'setuptools', 'wheel'], {
		env: runtime.env,
	});
	return venvPython;
}

async function resolveInstalledPython(runtime) {
	if (runtime.bundledPythonPath && (await pathExists(runtime.bundledPythonPath))) {
		await assertCommandWorks(
			runtime.bundledPythonPath,
			['--version'],
			`Bundled Python runtime is not executable at ${runtime.bundledPythonPath}. Reinstall the SpeekCoding package.`,
			'BUNDLED_PYTHON_INVALID',
		);
		return runtime.bundledPythonPath;
	}
	return bootstrapPythonEnv(runtime);
}

async function checkAudioRuntime(runtime) {
	const agent = await getAgentStatus(runtime, { launch: false });
	if (!agent.installed) {
		return { status: 'missing', detail: 'speek_coding_app_missing' };
	}
	return { status: agent.running ? 'ok' : 'installed', detail: agent.error || null };
}

export async function installAsrRuntime(runtime) {
	const config = runtime.configFilePath ? await loadConfig(runtime) : DEFAULT_CONFIG;
	const qwen = config.asrBackend === 'qwen-mlx';
	const packageName = qwen ? 'mlx-qwen3-asr==0.4.4' : 'faster-whisper>=1.2,<2';
	if (runtime.bundledPythonPath && (await pathExists(runtime.bundledPythonPath))) {
		await execFile(runtime.bundledPythonPath, ['-B', '-c', qwen ? 'import mlx_qwen3_asr, mlx.core, mlx_lm' : 'import faster_whisper'], { env: runtime.env });
		await fs.mkdir(runtime.configDir, { recursive: true });
		await fs.copyFile(runtime.asrServerSourcePath, runtime.asrServerTargetPath);
		await fs.chmod(runtime.asrServerTargetPath, 0o755);
		return {
			pythonBin: runtime.bundledPythonPath,
			asrServerPath: runtime.asrServerTargetPath,
			package: qwen ? 'bundled Qwen3-ASR / MLX' : 'bundled faster-whisper',
		};
	}
	const venvPython = `${runtime.venvDir}/bin/python`;
	if (await pathExists(venvPython)) {
		await assertPython(runtime);
	} else {
		await bootstrapPythonEnv(runtime);
	}
	await fs.mkdir(runtime.configDir, { recursive: true });
	await fs.copyFile(runtime.asrServerSourcePath, runtime.asrServerTargetPath);
	await fs.chmod(runtime.asrServerTargetPath, 0o755);
	await execFile(venvPython, ['-m', 'pip', 'install', ...(qwen ? [packageName, 'mlx==0.30.6', 'mlx-lm==0.28.4'] : [packageName])], {
		env: runtime.env,
	});
	return {
		pythonBin: venvPython,
		asrServerPath: runtime.asrServerTargetPath,
		package: packageName,
	};
}

export function mergeConfig(existingConfig, overrides = {}) {
	const merged = { ...existingConfig, ...overrides };
	if (overrides.asrBackend && overrides.asrBackend !== existingConfig.asrBackend && overrides.asrModel == null) {
		merged.asrModel = overrides.asrBackend === 'qwen-mlx' ? QWEN_MODEL : 'whisper-large-v3-turbo';
	}
	const hasLocalServerOverride = overrides.asrHost != null || overrides.asrPort != null;
	if (hasLocalServerOverride && overrides.asrApiUrl == null) {
		try {
			const url = new URL(existingConfig.asrApiUrl || DEFAULT_CONFIG.asrApiUrl);
			const host = overrides.asrHost || existingConfig.asrHost || DEFAULT_CONFIG.asrHost;
			url.hostname = ['0.0.0.0', '::'].includes(host) ? '127.0.0.1' : host;
			url.port = String(overrides.asrPort || existingConfig.asrPort || DEFAULT_CONFIG.asrPort);
			url.pathname = '/v1/audio/transcriptions';
			url.search = '';
			url.hash = '';
			merged.asrApiUrl = url.toString();
		} catch {
			// normalizeConfig will retain the explicit server settings and the existing endpoint.
		}
	}
	return normalizeConfig(merged);
}

function normalizeTriggerMode(triggerMode) {
	if (!triggerMode) {
		return null;
	}
	const normalized = String(triggerMode).trim().toLowerCase();
	if (['keyboard', 'keyboard-only'].includes(normalized)) {
		return TRIGGER_MODE_KEYBOARD;
	}
	if (['keyboard+dji', 'keyboard+mic', 'dji', 'keyboard-and-dji'].includes(normalized)) {
		return TRIGGER_MODE_KEYBOARD_DJI;
	}
	throw new Error(`Unsupported trigger mode: ${triggerMode}`);
}

function normalizeProfileOptions(profileOptions = {}) {
	if (profileOptions.cloneProfileFrom && !profileOptions.profileStrategy) {
		return {
			profileStrategy: 'clone',
			sourceProfileName: profileOptions.cloneProfileFrom,
			newProfileName: profileOptions.newProfileName,
		};
	}
	if (profileOptions.profileName && !profileOptions.profileStrategy) {
		return {
			profileStrategy: 'existing',
			profileName: profileOptions.profileName,
		};
	}
	return {
		profileStrategy: profileOptions.profileStrategy || 'active',
		profileName: profileOptions.profileName,
		sourceProfileName: profileOptions.sourceProfileName,
		newProfileName: profileOptions.newProfileName,
	};
}

function hasExplicitProfileSelection(options = {}) {
	return Boolean(
		options.profileOptions ||
			options.profileName ||
			options.profileStrategy ||
			options.sourceProfileName ||
			options.newProfileName ||
			options.cloneProfileFrom,
	);
}

async function resolveInstallProfileOptions(runtime, options = {}) {
	if (options.profileOptions) {
		return options.profileOptions;
	}
	if (hasExplicitProfileSelection(options)) {
		return options;
	}
	const manifest = await readManifest(runtime);
	if (manifest?.profileName) {
		return {
			profileStrategy: 'existing',
			profileName: manifest.profileName,
		};
	}
	return { profileStrategy: 'active' };
}

function hasExplicitTriggerSelection(options = {}) {
	return Boolean(options.triggerMode);
}

async function resolveInstallTriggerMode(runtime, options = {}) {
	const explicitTriggerMode = normalizeTriggerMode(options.triggerMode);
	if (explicitTriggerMode) {
		return explicitTriggerMode;
	}
	const manifest = await readManifest(runtime);
	if (manifest?.triggerMode) {
		return inferTriggerMode(manifest);
	}
	const existingTemplateRule = await loadRuleTemplate(runtime, TRIGGER_MODE_KEYBOARD_DJI);
	const existingKarabinerConfig = await loadKarabinerConfig(runtime);
	const existingManagedProfiles = findManagedEntries(existingKarabinerConfig, existingTemplateRule);
	if (existingManagedProfiles.length > 0) {
		return inferTriggerMode(manifest, existingManagedProfiles);
	}
	const detectedDevice = await detectOptionalTriggerDevice(runtime);
	return detectedDevice.status === 'connected' ? TRIGGER_MODE_KEYBOARD_DJI : TRIGGER_MODE_KEYBOARD;
}

async function syncInstallation(runtime, { profileOptions = {}, configOverrides = {}, installedMode, triggerMode }) {
	const normalizedTriggerMode = normalizeTriggerMode(triggerMode) || TRIGGER_MODE_KEYBOARD;
	const detectedDevice = await detectOptionalTriggerDevice(runtime);
	const templateRule = await loadRuleTemplate(runtime, normalizedTriggerMode);
	const karabinerConfig = await loadKarabinerConfig(runtime);
	const existingConfig = await loadConfig(runtime);
	const nextConfig = mergeConfig(existingConfig, configOverrides);
	const resolvedProfile = resolveTargetProfile(karabinerConfig, normalizeProfileOptions(profileOptions));
	const { profileName: appliedProfileName } = syncManagedEntries(karabinerConfig, templateRule, resolvedProfile.profileName, {
		includeManagedDevice: normalizedTriggerMode === TRIGGER_MODE_KEYBOARD_DJI,
	});

	const asrPython = await resolveInstalledPython(runtime);
	await ensureIPCToken(runtime);
	const app = await copyScript(runtime);
	const installedConfig = await writeConfig(runtime, {
		...nextConfig,
		pythonBin: asrPython,
		asrHelperPath: '',
	});
	if (runtime.env.SPEEK_SKIP_AGENT_HEALTHCHECK !== '1') {
		await sendAgentCommand(runtime, { command: 'ping' }, { timeoutMs: 8000 });
	}
	const legacyStateDir = path.dirname(runtime.legacyAgentSocketPath);
	if (legacyStateDir !== runtime.stateDir) {
		try {
			await removeOwnedDirectory(legacyStateDir, runtime.uid);
		} catch (error) {
			if (error.code !== 'UNSAFE_STATE_DIRECTORY') throw error;
		}
	}
	await removeIfExists(path.join(runtime.stateDir, 'command.log'));
	await writeKarabinerConfig(runtime, karabinerConfig);
	const profileSwitch = await selectProfileViaCli(runtime, appliedProfileName);
	await removeIfExists(runtime.scriptTargetPath);
	await removeIfExists(runtime.recorderLauncherTargetPath);
	await removeIfExists(runtime.asrHelperTargetPath);
	await fs.rm(runtime.recorderAppTargetPath, { recursive: true, force: true });

	const manifest = {
		manifestVersion: MANIFEST_VERSION,
		installedMode,
		packageVersion: runtime.packageVersion,
		profileName: appliedProfileName,
		profileStrategy: resolvedProfile.profileStrategy,
		sourceProfileName: resolvedProfile.sourceProfileName,
		triggerMode: normalizedTriggerMode,
		speekCodingAppTargetPath: runtime.speekCodingAppTargetPath,
		speekCodingBundleIdentifier: 'com.speek.coding',
		agentSocketPath: runtime.agentSocketPath,
		ipcTokenPath: runtime.ipcTokenPath,
		appSigningIdentity: app.signingIdentity,
		appDesignatedRequirement: app.designatedRequirement,
		asrServerTargetPath: runtime.asrServerTargetPath,
		hudTargetPath: runtime.hudTargetPath,
		venvDir: runtime.venvDir,
		bundledPythonPath: runtime.bundledPythonPath || null,
		configFilePath: runtime.configFilePath,
		updatedAt: new Date().toISOString(),
	};
	await writeManifest(runtime, manifest);
	const permissions = filterInstallPermissionReport(await detectPermissions(runtime));

	return {
		config: installedConfig,
		manifest,
		device: resolveConnectedDeviceStatus(normalizedTriggerMode, detectedDevice),
		permissions,
		profileName: appliedProfileName,
		profileStrategy: resolvedProfile.profileStrategy,
		triggerMode: normalizedTriggerMode,
		profileSwitch,
	};
}

export async function getKarabinerProfiles(runtime) {
	const karabinerConfig = await loadKarabinerConfig(runtime);
	return listProfiles(karabinerConfig);
}

export async function install(runtime, options = {}) {
	await assertInstallationPrerequisites(runtime);

	return syncInstallation(runtime, {
		profileOptions: await resolveInstallProfileOptions(runtime, options),
		triggerMode: await resolveInstallTriggerMode(runtime, options),
		configOverrides: options.configOverrides,
		installedMode: 'install',
	});
}

export async function update(runtime, options = {}) {
	await assertInstallationPrerequisites(runtime);

	const manifest = await readManifest(runtime);
	const templateRule = await loadRuleTemplate(runtime);
	const karabinerConfig = await loadKarabinerConfig(runtime);
	const managedProfiles = findManagedEntries(karabinerConfig, templateRule);
	const scriptInstalled = await pathExists(runtime.scriptTargetPath);

	if (!manifest && managedProfiles.length === 0 && !scriptInstalled) {
		throw createCommandError('No existing installation found. Run install first.', 'NOT_INSTALLED');
	}

	return syncInstallation(runtime, {
		profileOptions:
			options.profileOptions ||
			(options.profileName || options.profileStrategy || options.sourceProfileName || options.newProfileName || options.cloneProfileFrom
				? options
				: {
					profileStrategy: 'existing',
					profileName: manifest?.profileName || managedProfiles.find((profile) => profile.selected)?.name || managedProfiles[0]?.name,
				}),
		triggerMode:
			hasExplicitTriggerSelection(options) ? normalizeTriggerMode(options.triggerMode) : inferTriggerMode(manifest, managedProfiles),
		configOverrides: options.configOverrides,
		installedMode: 'update',
	});
}

export async function configureInstallation(runtime, configOverrides = {}) {
	const currentConfig = await loadConfig(runtime);
	const nextConfig = mergeConfig(currentConfig, configOverrides);
	await writeConfig(runtime, nextConfig);
	return nextConfig;
}

export async function testRecord(runtime, options = {}) {
	const config = await loadConfig(runtime);
	const durationSeconds = Number(options.durationSeconds || 2);
	if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
		throw createCommandError(`Invalid test record duration: ${options.durationSeconds}`, 'INVALID_DURATION');
	}
	const wavPath = options.wavPath || path.join(runtime.stateDir, 'test-record.wav');
	await fs.mkdir(path.dirname(wavPath), { recursive: true });
	const response = await sendAgentCommand(
		runtime,
		{
			command: 'test-record',
			durationSeconds,
			wavPath,
			sampleRate: config.audioSampleRate,
			deviceName: config.audioInputDeviceName,
		},
		{ timeoutMs: Math.ceil(durationSeconds * 1000) + 15000 },
	);
	const result = response.result || response;
	const stat = await fs.stat(result.wavPath || wavPath);
	return {
		wavPath: result.wavPath || wavPath,
		durationSeconds,
		bytes: stat.size,
		audioInputDeviceName: config.audioInputDeviceName,
		audioInputDeviceIndex: config.audioInputDeviceIndex,
		audioSampleRate: config.audioSampleRate,
		stdout: '',
		stderr: '',
		nativeApp: true,
	};
}

export async function uninstall(runtime) {
	for (const socketPath of new Set([runtime.agentSocketPath, runtime.legacyAgentSocketPath])) {
		await shutdownAgentAtSocket(runtime, socketPath, { strict: socketPath === runtime.agentSocketPath });
	}
	await uninstallAsrService(runtime);
	const templateRule = await loadRuleTemplate(runtime);
	let removedRuleCount = 0;
	let removedDeviceCount = 0;

	if (await pathExists(runtime.karabinerConfigPath)) {
		const karabinerConfig = await loadKarabinerConfig(runtime);
		const removed = removeManagedEntries(karabinerConfig, templateRule);
		removedRuleCount = removed.removedRuleCount;
		removedDeviceCount = removed.removedDeviceCount;
		await writeKarabinerConfig(runtime, karabinerConfig);
	}

	await removeIfExists(runtime.scriptTargetPath);
	await removeIfExists(runtime.recorderLauncherTargetPath);
	await removeIfExists(runtime.speekCommandTargetPath);
	await fs.rm(runtime.recorderAppTargetPath, { recursive: true, force: true });
	if (!runtime.packagedInstallation) {
		await fs.rm(runtime.speekCodingAppTargetPath, { recursive: true, force: true });
	}
	await removeIfExists(runtime.asrHelperTargetPath);
	await removeIfExists(runtime.asrServerTargetPath);
	await removeIfExists(runtime.hudTargetPath);
	await removeIfExists(runtime.configFilePath);
	await removeIfExists(runtime.manifestFilePath);
	await removeIfExists(runtime.ipcTokenPath);
	await fs.rm(runtime.venvDir, { recursive: true, force: true });
	await fs.rm(runtime.logsDir, { recursive: true, force: true });
	await removeOwnedDirectory(runtime.stateDir, runtime.uid);
	const legacyStateDir = path.dirname(runtime.legacyAgentSocketPath);
	if (legacyStateDir !== runtime.stateDir) {
		await removeOwnedDirectory(legacyStateDir, runtime.uid);
	}

	try {
		await fs.rmdir(runtime.configDir);
	} catch (error) {
		if (!['ENOENT', 'ENOTEMPTY'].includes(error.code)) {
			throw error;
		}
	}

	return { removedRuleCount, removedDeviceCount };
}

export async function doctor(runtime) {
	const karabinerConfigExists = await pathExists(runtime.karabinerConfigPath);
	const karabinerCliExists = await pathExists(runtime.karabinerCliPath);
	const pythonAvailable = runtime.packagedInstallation
		? null
		: await commandWorks(runtime.systemPythonPath, ['--version']);
	const swiftcAvailable = runtime.packagedInstallation
		? null
		: await commandWorks(runtime.swiftcPath, ['--version']);
	const bundledPythonAvailable = Boolean(
		runtime.bundledPythonPath && (await commandWorks(runtime.bundledPythonPath, ['--version'])),
	);
	const scriptInstalled = await pathExists(runtime.scriptTargetPath);
	const recorderLauncherInstalled = await pathExists(runtime.recorderLauncherTargetPath);
	const recorderAppInstalled = await pathExists(runtime.recorderAppTargetPath);
	const asrHelperInstalled = await pathExists(runtime.asrHelperTargetPath);
	const speekCommandInstalled = await pathExists(runtime.speekCommandTargetPath);
	const speekCodingAppInstalled = await pathExists(runtime.speekCodingAppTargetPath);
	const asrServerInstalled = await pathExists(runtime.asrServerTargetPath);
	const hudInstalled = await pathExists(runtime.hudTargetPath);
	const venvPythonExists = await pathExists(`${runtime.venvDir}/bin/python`);
	const configInstalled = await pathExists(runtime.configFilePath);
	const manifest = await readManifest(runtime);

	let managedProfiles = [];
	let profileCurrent = false;
	let triggerMode = inferTriggerMode(manifest);
	if (karabinerConfigExists) {
		const karabinerConfig = await loadKarabinerConfig(runtime);
		const templateRule = await loadRuleTemplate(runtime, inferTriggerMode(manifest, managedProfiles));
		managedProfiles = findManagedEntries(karabinerConfig, templateRule);
		triggerMode = inferTriggerMode(manifest, managedProfiles);
		const activeProfileName = manifest?.profileName || managedProfiles.find((profile) => profile.selected)?.name;
		if (activeProfileName) {
			try {
				const currentTemplateRule = await loadRuleTemplate(runtime, triggerMode);
				const activeProfile = findProfile(karabinerConfig, activeProfileName);
				profileCurrent = isManagedRuleCurrent(activeProfile, currentTemplateRule);
			} catch {
				profileCurrent = false;
			}
		}
	}

	const connectedDevice = resolveConnectedDeviceStatus(triggerMode, await detectOptionalTriggerDevice(runtime));
	const installed = Boolean(manifest || speekCodingAppInstalled || scriptInstalled || managedProfiles.length > 0);
	const packageVersion = runtime.packageVersion;
	const installedVersion = manifest?.packageVersion || null;
	const permissions = await detectPermissions(runtime);
	const audioRuntime = await checkAudioRuntime(runtime);
	let appSignature = { status: 'missing', detail: null };
	if (speekCodingAppInstalled) {
		try {
			await execFile(runtime.codesignPath, ['--verify', '--deep', '--strict', runtime.speekCodingAppTargetPath], {
				env: runtime.env,
			});
			appSignature = {
				status: 'ok',
				detail: await readDesignatedRequirement(runtime, runtime.speekCodingAppTargetPath),
			};
		} catch (error) {
			appSignature = { status: 'failed', detail: error.stderr?.trim() || error.message };
		}
	}
	const agent = await getAgentStatus(runtime, { launch: false });

	return {
		packageVersion,
		installedVersion,
		updateAvailable: Boolean(installedVersion && installedVersion !== packageVersion),
		installed,
		pythonAvailable,
		swiftcAvailable,
		bundledPythonAvailable,
		packagedInstallation: Boolean(runtime.packagedInstallation),
		karabinerCliExists,
		karabinerConfigExists,
		scriptInstalled,
		recorderLauncherInstalled,
		recorderAppInstalled,
		asrHelperInstalled,
		speekCommandInstalled,
		speekCodingAppInstalled,
		speekCodingAppPath: runtime.speekCodingAppTargetPath,
		appSignature,
		agent,
		asrServerInstalled,
		hudInstalled,
		venvPythonExists,
		audioRuntime,
		configInstalled,
		manifestExists: Boolean(manifest),
		managedProfiles,
		profileCurrent,
		triggerMode,
		connectedDevice,
		permissions,
	};
}

export { DEFAULT_CONFIG };
