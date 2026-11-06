import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const root = path.resolve(new URL('..', import.meta.url).pathname);

test('offline license catalog covers the project, locked dependencies, models and native codecs', async () => {
	const text = await fs.readFile(path.join(root, 'licenses/LICENSES.txt'), 'utf8');
	const projectLicense = await fs.readFile(path.join(root, 'LICENSE'), 'utf8');
	assert.ok(text.includes(projectLicense.trim()));
	const catalog = JSON.parse(await fs.readFile(path.join(root, 'licenses/catalog.json'), 'utf8'));
	for (const component of catalog.external) assert.ok(text.includes(component.name), component.name);
	for (const file of ['requirements-asr.in', 'requirements-mlx.in']) {
		const pins = await fs.readFile(path.join(root, 'packaging', file), 'utf8');
		for (const match of pins.matchAll(/^([\w.-]+)==([^\s]+)$/gmu)) {
			const name = match[1].toLowerCase().replaceAll('_', '-').replaceAll('.', '-');
			assert.ok(text.includes(`Component: python/${name}==${match[2]}`), match[0]);
		}
	}
	const lock = JSON.parse(await fs.readFile(path.join(root, 'package-lock.json'), 'utf8'));
	for (const [name, metadata] of Object.entries(lock.packages)) {
		if (name) assert.ok(text.includes(`Component: npm/${name.replace('node_modules/', '')}==${metadata.version}`), name);
	}
	for (const required of ['Qwen3-ASR-0.6B-4bit', 'Whisper', 'Apache License', 'NATIVE COMPONENT / FFmpeg', 'NATIVE COMPONENT / x264', 'GNU GENERAL PUBLIC LICENSE', 'GNU LESSER GENERAL PUBLIC LICENSE']) {
		assert.ok(text.includes(required), required);
	}
});

test('license generator collects actual dependency texts and fails on omissions', async (context) => {
	const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'speek-licenses-'));
	context.after(() => fs.rm(directory, { recursive: true, force: true }));
	const resources = path.join(directory, 'Resources');
	async function put(relative, content) {
		const target = path.join(resources, relative);
		await fs.mkdir(path.dirname(target), { recursive: true });
		await fs.writeFile(target, content);
	}
	await put('licenses/Node.js-LICENSE', 'Node runtime license fixture');
	await put('runtime/python/lib/python3.12/LICENSE.txt', 'CPython license fixture');
	await put('node_modules/example/package.json', JSON.stringify({ name: 'example', version: '1.0', license: 'MIT' }));
	await put('node_modules/example/LICENSE', 'NPM copyright fixture');
	const dist = 'runtime/python/lib/python3.12/site-packages/example-1.0.dist-info';
	await put(`${dist}/METADATA`, 'Metadata-Version: 2.1\nName: example\nVersion: 1.0\nLicense: MIT\n');
	await put(`${dist}/RECORD`, 'example-1.0.dist-info/METADATA,,\nexample-1.0.dist-info/licenses/LICENSE,,\n');
	await put(`${dist}/licenses/LICENSE`, 'Python copyright fixture');
	const output = path.join(directory, 'LICENSES.txt');
	const args = [path.join(root, 'scripts/generate-license-notices.py'), '--project-root', root, '--resources', resources, '--output', output];
	await execute('python3', args);
	const text = await fs.readFile(output, 'utf8');
	for (const marker of ['Component: npm/example==1.0', 'Component: python/example==1.0', 'NPM copyright fixture', 'Python copyright fixture']) assert.ok(text.includes(marker));
	assert.ok(!text.includes(directory));
	await fs.rm(path.join(resources, dist, 'licenses/LICENSE'));
	await assert.rejects(execute('python3', args), (error) => /No license found for Python example/u.test(error.stderr));
	await put(`${dist}/licenses/LICENSE`, 'Python copyright fixture');
	await put('runtime/python/lib/python3.12/site-packages/av/.dylibs/libunregistered.dylib', 'fixture');
	await assert.rejects(execute('python3', args), (error) => /Missing native library notices/u.test(error.stderr));
});
