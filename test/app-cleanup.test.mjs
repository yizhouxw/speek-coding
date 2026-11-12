import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { cleanupOldApps, registeredApps } from '../cli/lib/app-cleanup.mjs';

const bundle = 'com.speek.coding';
const record = (p, id = bundle) => `path: ${p} (0x123a)\nidentifier: ${id}\n`;

test('registration parser matches only the exact app identifier', () => {
	assert.deepEqual([...registeredApps(record('/a b/SpeekCoding.app') + record('/probe.app', `${bundle}.inputprobe`))], ['/a b/SpeekCoding.app']);
});

async function fixture(t) {
	const home = await fs.mkdtemp(path.join(await fs.realpath(os.tmpdir()), 'speek-cleanup-'));
	t.after(() => fs.rm(home, { recursive: true, force: true }));
	const apps = path.join(home, 'Applications');
	const runtime = { homeDir: home, repoRoot: path.join(home, 'repo'), env: {}, configDir: path.join(home, '.config/speek-coding'), venvDir: path.join(home, '.config/speek-coding/venv'), speekCodingAppTargetPath: path.join(apps, 'SpeekCoding.app') };
	const ids = new Map();
	async function app(p, id = bundle) {
		await fs.mkdir(path.join(p, 'Contents'), { recursive: true });
		ids.set(path.join(p, 'Contents/Info.plist'), id);
		return p;
	}
	await app(runtime.speekCodingAppTargetPath);
	const calls = [];
	const state = { dump: '', processes: '', fail: null };
	const run = async (command, args) => {
		calls.push([command, args]);
		if (args.includes(state.fail)) throw new Error('simulated failure');
		if (args[0] === '-dump') return { stdout: state.dump };
		if (command === '/bin/ps') return { stdout: state.processes };
		if (command === '/usr/bin/plutil') return { stdout: ids.get(args.at(-1)) || 'another.app' };
		return { stdout: '' };
	};
	return { runtime, apps, app, calls, state, cleanup: config => cleanupOldApps(runtime, config || {}, { run, applicationRoots: [apps] }) };
}

test('removes old installed/build apps and stale registrations, preserving current app and cached models', async t => {
	const f = await fixture(t);
	const old = await f.app(path.join(f.apps, 'SpeekCoding-old.app'));
	const build = await f.app(path.join(f.runtime.repoRoot, 'build/package-arm64/root/Applications/SpeekCoding.app'));
	const stale = path.join(f.runtime.homeDir, 'gone.app');
	f.state.dump = record(old) + record(build) + record(stale) + record(f.runtime.speekCodingAppTargetPath);
	const model = path.join(f.runtime.homeDir, '.cache/huggingface/hub/weights');
	await fs.mkdir(path.dirname(model), { recursive: true });
	await fs.writeFile(model, 'model weights');
	const before = await fs.stat(model);
	const result = await f.cleanup();
	assert.deepEqual(new Set(result.removed), new Set([old, build]));
	assert.deepEqual(result.warnings, []);
	assert.ok(result.unregistered.includes(stale));
	await assert.rejects(fs.stat(old), { code: 'ENOENT' });
	await fs.stat(f.runtime.speekCodingAppTargetPath);
	assert.equal((await fs.stat(model)).ino, before.ino);
	assert.equal(await fs.readFile(model, 'utf8'), 'model weights');
	assert.deepEqual(f.calls.at(-1)[1], ['-f', f.runtime.speekCodingAppTargetPath]);
	f.state.dump = record(f.runtime.speekCodingAppTargetPath);
	assert.deepEqual((await f.cleanup()).removed, []);
});

test('keeps running apps, unrelated bundles, current aliases, custom models and selected Python', async t => {
	const f = await fixture(t);
	const running = await f.app(path.join(f.apps, 'SpeekCoding-running.app'));
	const other = await f.app(path.join(f.apps, 'SpeekCoding-other.app'), 'other.bundle');
	const models = await f.app(path.join(f.apps, 'SpeekCoding-models.app'));
	const python = await f.app(path.join(f.apps, 'SpeekCoding-python.app'));
	const alias = path.join(f.apps, 'SpeekCoding-alias.app');
	await fs.symlink(f.runtime.speekCodingAppTargetPath, alias);
	f.runtime.env.HF_HOME = path.join(models, 'models');
	f.state.processes = `${running}/Contents/MacOS/SpeekCoding\n`;
	f.state.dump = [running, other, models, python, alias].map(p => record(p)).join('');
	const result = await f.cleanup({ pythonBin: path.join(python, 'bin/python') });
	assert.deepEqual(result.removed, []);
	assert.deepEqual(result.unregistered, []);
	assert.equal(result.warnings.length, 1);
	for (const p of [running, other, models, python, alias]) await fs.stat(p);
});

test('cleanup failures are reported without deleting the old app; skipped checks disable cleanup', async t => {
	const f = await fixture(t);
	const old = await f.app(path.join(f.apps, 'SpeekCoding-old.app'));
	f.state.fail = '-u';
	const result = await f.cleanup();
	assert.equal(result.warnings.length, 1);
	await fs.stat(old);
	f.runtime.env.SPEEK_SKIP_AGENT_HEALTHCHECK = '1';
	f.calls.length = 0;
	assert.deepEqual(await f.cleanup(), { removed: [], unregistered: [], warnings: [] });
	assert.equal(f.calls.length, 0);
});
