import { execFile as execFileCallback } from 'node:child_process';
import fs from 'node:fs/promises';
import { promisify } from 'node:util';

import { loadConfig } from './config.mjs';

const execFile = promisify(execFileCallback);

export const ASR_SERVICE_LABEL = 'com.speek.coding.asr';

function xmlEscape(value) {
	return String(value)
		.replaceAll('&', '&amp;')
		.replaceAll('<', '&lt;')
		.replaceAll('>', '&gt;')
		.replaceAll('"', '&quot;')
		.replaceAll("'", '&apos;');
}

async function pathExists(filePath) {
	try {
		await fs.access(filePath);
		return true;
	} catch {
		return false;
	}
}

function createServiceError(message, code, cause) {
	const error = new Error(message);
	error.code = code;
	if (cause) {
		error.cause = cause;
	}
	return error;
}

function assertLaunchdRuntime(runtime) {
	if (process.platform !== 'darwin') {
		throw createServiceError('The background ASR service is only supported on macOS.', 'UNSUPPORTED_PLATFORM');
	}
	if (runtime.uid == null) {
		throw createServiceError('Unable to determine the current macOS user id.', 'USER_ID_UNAVAILABLE');
	}
}

export function buildAsrServerArgs(runtime, config) {
	const args = [
		runtime.asrServerTargetPath,
		'--host',
		config.asrHost,
		'--port',
		String(config.asrPort),
		'--backend',
		config.asrBackend,
		'--model',
		config.asrModel,
		'--device',
		config.asrDevice,
		'--compute-type',
		config.asrComputeType,
		'--cpu-threads',
		String(config.asrCpuThreads),
		'--beam-size',
		String(config.asrBeamSize),
		'--best-of',
		String(config.asrBestOf),
		'--whisper-cpp-timeout',
		String(config.whisperCppTimeout),
	];
	if (config.whisperCppBin) {
		args.push('--whisper-cpp-bin', config.whisperCppBin);
	}
	if (!config.asrVadFilter) {
		args.push('--no-vad-filter');
	}
	if (config.asrQuiet) {
		args.push('--quiet');
	}
	return args;
}

export function buildLaunchAgentPlist(runtime, config) {
	const pythonBin = config.pythonBin || `${runtime.venvDir}/bin/python`;
	const programArguments = [pythonBin, '-B', ...buildAsrServerArgs(runtime, config)]
		.map((argument) => `\t\t<string>${xmlEscape(argument)}</string>`)
		.join('\n');
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>${ASR_SERVICE_LABEL}</string>
\t<key>ProgramArguments</key>
\t<array>
${programArguments}
\t</array>
\t<key>RunAtLoad</key>
\t<true/>
\t<key>KeepAlive</key>
\t<dict>
\t\t<key>SuccessfulExit</key>
\t\t<false/>
\t</dict>
\t<key>ProcessType</key>
\t<string>Interactive</string>
\t<key>Umask</key>
\t<integer>63</integer>
\t<key>StandardOutPath</key>
\t<string>${xmlEscape(runtime.asrStdoutLogPath)}</string>
\t<key>StandardErrorPath</key>
\t<string>${xmlEscape(runtime.asrStderrLogPath)}</string>
\t<key>EnvironmentVariables</key>
\t<dict>
\t\t<key>PATH</key>
\t\t<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
\t</dict>
</dict>
</plist>
`;
}

function launchdDomain(runtime) {
	return `gui/${runtime.uid}`;
}

function launchdTarget(runtime) {
	return `${launchdDomain(runtime)}/${ASR_SERVICE_LABEL}`;
}

async function runLaunchctl(runtime, args, { ignoreFailure = false } = {}) {
	try {
		return await execFile(runtime.launchctlPath, args, { env: runtime.env });
	} catch (error) {
		if (ignoreFailure) {
			return null;
		}
		throw createServiceError(
			`launchctl ${args[0]} failed: ${(error.stderr || error.message).trim()}`,
			'LAUNCHCTL_FAILED',
			error,
		);
	}
}

async function isServiceLoaded(runtime) {
	const result = await runLaunchctl(runtime, ['print', launchdTarget(runtime)], { ignoreFailure: true });
	return result != null;
}

async function assertServiceFiles(runtime, config) {
	const pythonBin = config.pythonBin || `${runtime.venvDir}/bin/python`;
	if (!(await pathExists(pythonBin))) {
		throw createServiceError(
			`Local ASR runtime not found at ${pythonBin}. Run \`speek asr-install\` first.`,
			'PYTHON_VENV_MISSING',
		);
	}
	if (!(await pathExists(runtime.asrServerTargetPath))) {
		throw createServiceError(
			`ASR server not found at ${runtime.asrServerTargetPath}. Run \`speek asr-install\` first.`,
			'ASR_SERVER_MISSING',
		);
	}
}

export async function installAsrService(runtime, { start = true } = {}) {
	assertLaunchdRuntime(runtime);
	const config = await loadConfig(runtime);
	await assertServiceFiles(runtime, config);
	await fs.mkdir(runtime.launchAgentsDir, { recursive: true });
	await fs.mkdir(runtime.logsDir, { recursive: true, mode: 0o700 });
	await fs.chmod(runtime.logsDir, 0o700);
	try {
		await fs.writeFile(runtime.servicePlistPath, buildLaunchAgentPlist(runtime, config), {
			encoding: 'utf-8',
			mode: 0o600,
		});
		await fs.chmod(runtime.servicePlistPath, 0o600);
	} catch (error) {
		if (
			error.code !== 'EPERM' ||
			!runtime.fallbackServicePlistPath ||
			runtime.servicePlistPath === runtime.fallbackServicePlistPath
		) {
			throw error;
		}
		runtime.servicePlistPath = runtime.fallbackServicePlistPath;
		await fs.mkdir(runtime.configDir, { recursive: true, mode: 0o700 });
		await fs.chmod(runtime.configDir, 0o700);
		await fs.writeFile(runtime.servicePlistPath, buildLaunchAgentPlist(runtime, config), {
			encoding: 'utf-8',
			mode: 0o600,
		});
		await fs.chmod(runtime.servicePlistPath, 0o600);
	}
	await runLaunchctl(runtime, ['bootout', launchdTarget(runtime)], { ignoreFailure: true });
	await runLaunchctl(runtime, ['bootstrap', launchdDomain(runtime), runtime.servicePlistPath]);
	await runLaunchctl(runtime, ['enable', launchdTarget(runtime)], { ignoreFailure: true });
	if (start) {
		await runLaunchctl(runtime, ['kickstart', '-k', launchdTarget(runtime)]);
	}
	return getAsrServiceStatus(runtime);
}

export async function startAsrService(runtime) {
	assertLaunchdRuntime(runtime);
	const config = await loadConfig(runtime);
	await assertServiceFiles(runtime, config);
	if (!(await pathExists(runtime.servicePlistPath))) {
		return installAsrService(runtime, { start: true });
	}
	if (!(await isServiceLoaded(runtime))) {
		await runLaunchctl(runtime, ['bootstrap', launchdDomain(runtime), runtime.servicePlistPath]);
	}
	await runLaunchctl(runtime, ['kickstart', '-k', launchdTarget(runtime)]);
	return getAsrServiceStatus(runtime);
}

export async function stopAsrService(runtime) {
	assertLaunchdRuntime(runtime);
	await runLaunchctl(runtime, ['bootout', launchdTarget(runtime)], { ignoreFailure: true });
	return getAsrServiceStatus(runtime, { probeHealth: false });
}

export async function restartAsrService(runtime) {
	return installAsrService(runtime, { start: true });
}

export async function uninstallAsrService(runtime) {
	if (process.platform === 'darwin' && runtime.uid != null) {
		await runLaunchctl(runtime, ['bootout', launchdTarget(runtime)], { ignoreFailure: true });
	}
	await fs.rm(runtime.servicePlistPath, { force: true });
	if (runtime.preferredServicePlistPath) {
		await fs.rm(runtime.preferredServicePlistPath, { force: true });
	}
	if (runtime.fallbackServicePlistPath) {
		await fs.rm(runtime.fallbackServicePlistPath, { force: true });
	}
}

export function healthUrlFromTranscriptionUrl(transcriptionUrl) {
	try {
		const url = new URL(transcriptionUrl);
		url.pathname = '/health';
		url.search = '';
		url.hash = '';
		return url.toString();
	} catch {
		return null;
	}
}

export async function probeAsrHealth(transcriptionUrl, { timeoutMs = 1200, fetchImpl = fetch } = {}) {
	const healthUrl = healthUrlFromTranscriptionUrl(transcriptionUrl);
	if (!healthUrl) {
		return { ok: false, url: null, error: 'invalid_asr_url' };
	}
	try {
		const response = await fetchImpl(healthUrl, { signal: AbortSignal.timeout(timeoutMs) });
		if (!response.ok) {
			return { ok: false, url: healthUrl, error: `http_${response.status}` };
		}
		const details = await response.json();
		return { ok: true, url: healthUrl, details };
	} catch (error) {
		return { ok: false, url: healthUrl, error: error.name === 'TimeoutError' ? 'timeout' : error.message };
	}
}

export async function getAsrServiceStatus(runtime, { probeHealth = true } = {}) {
	const config = await loadConfig(runtime);
	const installed = await pathExists(runtime.servicePlistPath);
	const bypassed = Boolean(config.fakeTranscript);
	let loaded = false;
	if (process.platform === 'darwin' && runtime.uid != null) {
		loaded = await isServiceLoaded(runtime);
	}
	const health = probeHealth && !bypassed
		? await probeAsrHealth(config.asrApiUrl)
		: { ok: false, url: healthUrlFromTranscriptionUrl(config.asrApiUrl), error: 'not_checked' };
	return {
		label: ASR_SERVICE_LABEL,
		installed,
		loaded,
		bypassed,
		startsAtLogin: runtime.servicePlistPath === runtime.preferredServicePlistPath,
		health,
		plistPath: runtime.servicePlistPath,
		stdoutLogPath: runtime.asrStdoutLogPath,
		stderrLogPath: runtime.asrStderrLogPath,
	};
}
