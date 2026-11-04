import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { DEFAULT_CONFIG, writeConfig } from '../cli/lib/config.mjs';
import {
	buildAsrServerArgs,
	buildLaunchAgentPlist,
	healthUrlFromTranscriptionUrl,
	installAsrService,
	probeAsrHealth,
	uninstallAsrService,
} from '../cli/lib/service.mjs';

const runtime = {
	asrServerTargetPath: '/Users/Test & Co/.config/speek/local-asr-server.py',
	venvDir: '/Users/Test & Co/.config/speek/venv',
	asrStdoutLogPath: '/Users/Test & Co/.config/speek/logs/asr.log',
	asrStderrLogPath: '/Users/Test & Co/.config/speek/logs/asr-error.log',
};

test('buildAsrServerArgs reflects persisted backend settings', () => {
	const args = buildAsrServerArgs(runtime, {
		...DEFAULT_CONFIG,
		asrBackend: 'whisper-cpp',
		whisperCppBin: '/opt/homebrew/bin/whisper-cli',
		asrVadFilter: false,
	});
	assert.deepEqual(args.slice(0, 5), [runtime.asrServerTargetPath, '--host', '127.0.0.1', '--port', '8000']);
	assert.ok(args.includes('whisper-cpp'));
	assert.ok(args.includes('/opt/homebrew/bin/whisper-cli'));
	assert.ok(args.includes('--no-vad-filter'));
});

test('buildLaunchAgentPlist escapes paths and starts at login', () => {
	const plist = buildLaunchAgentPlist(runtime, {
		...DEFAULT_CONFIG,
		pythonBin: '/Applications/SpeekCoding.app/Contents/Resources/runtime/python/bin/python3',
	});
	assert.match(plist, /com\.speek\.coding\.asr/u);
	assert.match(plist, /Users\/Test &amp; Co/u);
	assert.match(plist, /Applications\/SpeekCoding\.app\/Contents\/Resources\/runtime\/python\/bin\/python3/u);
	assert.match(plist, /<string>-B<\/string>\s*<string>[^<]*local-asr-server\.py<\/string>/u);
	assert.match(plist, /<key>RunAtLoad<\/key>\s*<true\/>/u);
	assert.match(plist, /<key>Umask<\/key>\s*<integer>63<\/integer>/u);
});

test('health endpoint is derived from a transcription URL', () => {
	assert.equal(
		healthUrlFromTranscriptionUrl('http://127.0.0.1:8000/v1/audio/transcriptions?x=1'),
		'http://127.0.0.1:8000/health',
	);
	assert.equal(healthUrlFromTranscriptionUrl('not a url'), null);
});

test('probeAsrHealth returns structured health details', async () => {
	const result = await probeAsrHealth(DEFAULT_CONFIG.asrApiUrl, {
		fetchImpl: async () => ({ ok: true, json: async () => ({ ok: true, backend: 'test' }) }),
	});
	assert.equal(result.ok, true);
	assert.equal(result.details.backend, 'test');
});

test('service install and uninstall manage the LaunchAgent file', async (context) => {
	const homeDir = await fs.mkdtemp(path.join(os.tmpdir(), 'speek-service-'));
	context.after(() => fs.rm(homeDir, { recursive: true, force: true }));
	const configDir = path.join(homeDir, '.config', 'speek-coding');
	const venvDir = path.join(configDir, 'venv');
	const logsDir = path.join(configDir, 'logs');
	const launchAgentsDir = path.join(homeDir, 'Library', 'LaunchAgents');
	const serviceRuntime = {
		env: process.env,
		uid: process.getuid(),
		launchctlPath: '/usr/bin/true',
		configDir,
		configFilePath: path.join(configDir, 'config.env'),
		venvDir,
		logsDir,
		launchAgentsDir,
		servicePlistPath: path.join(launchAgentsDir, 'com.speek.coding.asr.plist'),
		asrServerTargetPath: path.join(configDir, 'local-asr-server.py'),
		asrStdoutLogPath: path.join(logsDir, 'asr.log'),
		asrStderrLogPath: path.join(logsDir, 'asr-error.log'),
	};
	await fs.mkdir(path.join(venvDir, 'bin'), { recursive: true });
	await fs.writeFile(path.join(venvDir, 'bin', 'python'), '', 'utf-8');
	await fs.writeFile(serviceRuntime.asrServerTargetPath, '', 'utf-8');
	await writeConfig(serviceRuntime, { ...DEFAULT_CONFIG, fakeTranscript: 'test' });

	const status = await installAsrService(serviceRuntime);
	assert.equal(status.installed, true);
	assert.equal(status.loaded, true);
	assert.equal(status.bypassed, true);
	assert.equal((await fs.stat(logsDir)).mode & 0o777, 0o700);
	assert.equal((await fs.stat(serviceRuntime.servicePlistPath)).mode & 0o777, 0o600);

	await uninstallAsrService(serviceRuntime);
	await assert.rejects(fs.access(serviceRuntime.servicePlistPath));
});
