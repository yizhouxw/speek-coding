import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { installAsrRuntime } from '../cli/lib/actions.mjs';
import { createRuntime } from '../cli/lib/runtime.mjs';

test('packaged runtime resolves App-owned Node-adjacent resources', () => {
	const packagedAppPath = '/Applications/SpeekCoding.app';
	const runtime = createRuntime({
		env: {
			...process.env,
			SPEEK_PACKAGED_APP_PATH: packagedAppPath,
		},
	});

	assert.equal(runtime.packagedInstallation, true);
	assert.equal(runtime.speekCodingAppTargetPath, packagedAppPath);
	assert.equal(runtime.prebuiltSpeekCodingAppPath, packagedAppPath);
	assert.equal(runtime.prebuiltHudPath, path.join(runtime.repoRoot, 'bin', 'speek-hud'));
	assert.equal(
		runtime.bundledPythonPath,
		path.join(runtime.repoRoot, 'runtime', 'python', 'bin', 'python3'),
	);
});

test('ASR installation reuses a bundled Python runtime without creating a venv', async (context) => {
	const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'speek-package-runtime-'));
	context.after(() => fs.rm(tempDir, { recursive: true, force: true }));
	const sourcePath = path.join(tempDir, 'source.py');
	const targetPath = path.join(tempDir, 'config', 'local-asr-server.py');
	await fs.writeFile(sourcePath, 'print("test")\n', 'utf-8');

	const result = await installAsrRuntime({
		env: process.env,
		bundledPythonPath: '/usr/bin/true',
		configDir: path.dirname(targetPath),
		asrServerSourcePath: sourcePath,
		asrServerTargetPath: targetPath,
		venvDir: path.join(tempDir, 'venv'),
	});

	assert.equal(result.pythonBin, '/usr/bin/true');
	assert.equal(result.package, 'bundled faster-whisper');
	assert.equal(await fs.readFile(targetPath, 'utf-8'), 'print("test")\n');
	await assert.rejects(fs.access(path.join(tempDir, 'venv')));
});
