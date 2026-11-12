import assert from 'node:assert/strict';
import test from 'node:test';

import { HELP_TEXT, parseArgs } from '../cli/lib/args.mjs';

test('parseArgs defaults to help', () => {
	assert.deepEqual(parseArgs([]), { command: 'help', flags: {} });
	assert.match(HELP_TEXT, /setup\s+Install Speek/u);
});

test('parseArgs reads product setup options', () => {
	assert.deepEqual(
		parseArgs([
			'setup',
			'--trigger-mode',
			'keyboard+dji',
			'--asr-backend',
			'whisper-cpp',
			'--no-start',
		]),
		{
			command: 'setup',
			flags: {
				triggerMode: 'keyboard+dji',
				asrBackend: 'whisper-cpp',
				noStart: true,
			},
		},
	);
});

test('parseArgs reports missing values and unknown flags', () => {
	assert.throws(() => parseArgs(['config', '--asr-model']), /Missing value/u);
	assert.throws(() => parseArgs(['status', '--mystery']), /Unknown option/u);
});

test('parseArgs accepts the transcript cleanup preference', () => {
	assert.deepEqual(parseArgs(['config', '--transcript-cleanup', 'off']), {
		command: 'config', flags: { transcriptCleanup: 'off' },
	});
});
