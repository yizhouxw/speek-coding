import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import test from 'node:test';

test('Qwen streaming HTTP lifecycle, revisions, limits, cancellation and thread ownership', async () => {
	await promisify(execFile)('python3', ['-B', new URL('./qwen-streaming.py', import.meta.url).pathname]);
});
