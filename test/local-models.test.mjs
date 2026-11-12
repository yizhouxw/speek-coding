import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('local correction handles cancellation, truncation and model validation', () => {
	execFileSync('python3', ['-B', fileURLToPath(new URL('./local-models.py', import.meta.url))]);
});
