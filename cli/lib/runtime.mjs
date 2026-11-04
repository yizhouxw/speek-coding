import os from 'node:os';
import path from 'node:path';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const APP_NAME = 'speek-coding';
const REPO_ROOT = path.resolve(fileURLToPath(new URL('../..', import.meta.url)));
const PACKAGE_JSON_PATH = path.join(REPO_ROOT, 'package.json');
const ASR_SERVER_SOURCE_PATH = path.join(REPO_ROOT, 'scripts', 'local-asr-server.py');
const HUD_SOURCE_PATH = path.join(REPO_ROOT, 'scripts', 'speek-hud.swift');
const SPEEK_CODING_APP_SOURCE_PATH = path.join(REPO_ROOT, 'scripts', 'speek-coding-app.swift');
const SPEEK_COMMAND_SOURCE_PATH = path.join(REPO_ROOT, 'scripts', 'speek-command.sh');
const SIGNING_IDENTITY_SCRIPT_PATH = path.join(REPO_ROOT, 'scripts', 'ensure-signing-identity.sh');
const KARABINER_TEMPLATE_PATH = path.join(REPO_ROOT, 'karabiner', 'dji-mic-mini.json');
const DEFAULT_KARABINER_CLI = '/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli';
const DEFAULT_SWIFTC = '/usr/bin/swiftc';
const DEFAULT_LAUNCHCTL = '/bin/launchctl';

function detectPackagedAppPath() {
	if (path.basename(REPO_ROOT) !== 'Resources') return null;
	const contentsDir = path.dirname(REPO_ROOT);
	const appPath = path.dirname(contentsDir);
	return path.basename(contentsDir) === 'Contents' && appPath.endsWith('.app') ? appPath : null;
}

let cachedPackageVersion;

function getPackageVersion() {
	if (!cachedPackageVersion) {
		cachedPackageVersion = JSON.parse(readFileSync(PACKAGE_JSON_PATH, 'utf-8')).version;
	}
	return cachedPackageVersion;
}

export function createRuntime({ env = process.env } = {}) {
	const packagedAppPath = env.SPEEK_PACKAGED_APP_PATH || detectPackagedAppPath();
	const homeDir = env.DJI_INSTALLER_HOME || os.homedir();
	const configDir = env.SPEEK_CONFIG_DIR || env.DJI_CONFIG_DIR || path.join(homeDir, '.config', APP_NAME);
	const karabinerDir = env.DJI_KARABINER_DIR || path.join(homeDir, '.config', 'karabiner');
	const karabinerScriptsDir = env.DJI_KARABINER_SCRIPTS_DIR || path.join(karabinerDir, 'scripts');
	const launchAgentsDir = env.SPEEK_LAUNCH_AGENTS_DIR || path.join(homeDir, 'Library', 'LaunchAgents');
	const logsDir = env.SPEEK_LOGS_DIR || path.join(configDir, 'logs');
	const uid = env.SPEEK_UID || (typeof process.getuid === 'function' ? process.getuid() : 'user');
	const stateDir = env.SPEEK_STATE_DIR || path.join('/tmp', `${APP_NAME}-${uid}`);
	const legacyStateDir = env.SPEEK_LEGACY_STATE_DIR || path.join('/tmp', APP_NAME);
	const preferredServicePlistPath = path.join(launchAgentsDir, 'com.speek.coding.asr.plist');
	const fallbackServicePlistPath = path.join(configDir, 'com.speek.coding.asr.plist');
	const servicePlistPath =
		env.SPEEK_SERVICE_PLIST ||
		(existsSync(preferredServicePlistPath)
			? preferredServicePlistPath
			: existsSync(fallbackServicePlistPath)
				? fallbackServicePlistPath
				: preferredServicePlistPath);

	return {
		env,
		homeDir,
		configDir,
		configFilePath: env.DJI_CONFIG_FILE || path.join(configDir, 'config.env'),
		manifestFilePath: env.DJI_INSTALLER_MANIFEST || path.join(configDir, 'install-state.json'),
		logsDir,
		stateDir,
		agentSocketPath: env.SPEEK_AGENT_SOCKET || path.join(stateDir, 'agent.sock'),
		legacyAgentSocketPath: path.join(legacyStateDir, 'agent.sock'),
		ipcTokenPath: env.SPEEK_IPC_TOKEN || path.join(configDir, 'ipc-token'),
		asrStdoutLogPath: env.SPEEK_ASR_STDOUT_LOG || path.join(logsDir, 'asr.log'),
		asrStderrLogPath: env.SPEEK_ASR_STDERR_LOG || path.join(logsDir, 'asr-error.log'),
		venvDir: env.SPEEK_VENV_DIR || path.join(configDir, 'venv'),
		launchAgentsDir,
		servicePlistPath,
		preferredServicePlistPath,
		fallbackServicePlistPath,
		karabinerDir,
		karabinerConfigPath: env.DJI_KARABINER_CONFIG || path.join(karabinerDir, 'karabiner.json'),
		karabinerScriptsDir,
		scriptTargetPath: env.DJI_SCRIPT_TARGET || path.join(karabinerScriptsDir, 'dictation-enter.sh'),
		asrHelperTargetPath: env.SPEEK_ASR_HELPER_TARGET || path.join(karabinerScriptsDir, 'local-asr-helper.py'),
		asrServerTargetPath: env.SPEEK_ASR_SERVER_TARGET || path.join(configDir, 'local-asr-server.py'),
		hudTargetPath: env.SPEEK_HUD_TARGET || path.join(karabinerScriptsDir, 'speek-hud'),
		speekCodingAppTargetPath:
			env.SPEEK_CODING_APP_TARGET || packagedAppPath || path.join(homeDir, 'Applications', 'SpeekCoding.app'),
		prebuiltSpeekCodingAppPath: env.SPEEK_PREBUILT_APP || packagedAppPath,
		prebuiltHudPath:
			env.SPEEK_PREBUILT_HUD || (packagedAppPath ? path.join(REPO_ROOT, 'bin', 'speek-hud') : null),
		bundledPythonPath:
			env.SPEEK_BUNDLED_PYTHON ||
			(packagedAppPath ? path.join(REPO_ROOT, 'runtime', 'python', 'bin', 'python3') : null),
		packagedInstallation: Boolean(packagedAppPath),
		speekCommandTargetPath: env.SPEEK_COMMAND_TARGET || path.join(karabinerScriptsDir, 'speek-command'),
		recorderAppTargetPath: env.SPEEK_RECORDER_APP_TARGET || path.join(configDir, 'SpeekRecorder.app'),
		recorderLauncherTargetPath: env.SPEEK_RECORDER_LAUNCHER_TARGET || path.join(karabinerScriptsDir, 'speek-recorder'),
		karabinerCliPath: env.DJI_KARABINER_CLI || DEFAULT_KARABINER_CLI,
		launchctlPath: env.SPEEK_LAUNCHCTL || DEFAULT_LAUNCHCTL,
		codesignPath: env.CODESIGN_BIN || '/usr/bin/codesign',
		securityPath: env.SECURITY_BIN || '/usr/bin/security',
		uid,
		systemPythonPath: env.PYTHON3_BIN || 'python3',
		swiftcPath: env.SWIFTC_BIN || DEFAULT_SWIFTC,
		soundDirectoryPath: env.DJI_SOUND_DIR || '/System/Library/Sounds',
		repoRoot: REPO_ROOT,
		asrServerSourcePath: ASR_SERVER_SOURCE_PATH,
		hudSourcePath: HUD_SOURCE_PATH,
		speekCodingAppSourcePath: SPEEK_CODING_APP_SOURCE_PATH,
		speekCommandSourcePath: SPEEK_COMMAND_SOURCE_PATH,
		signingIdentityScriptPath: SIGNING_IDENTITY_SCRIPT_PATH,
		karabinerTemplatePath: KARABINER_TEMPLATE_PATH,
		packageVersion: getPackageVersion(),
	};
}

export {
	APP_NAME,
	ASR_SERVER_SOURCE_PATH,
	DEFAULT_KARABINER_CLI,
	DEFAULT_LAUNCHCTL,
	DEFAULT_SWIFTC,
	HUD_SOURCE_PATH,
	KARABINER_TEMPLATE_PATH,
	REPO_ROOT,
	SPEEK_CODING_APP_SOURCE_PATH,
	SPEEK_COMMAND_SOURCE_PATH,
	SIGNING_IDENTITY_SCRIPT_PATH,
};
