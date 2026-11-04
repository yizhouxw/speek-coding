import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import {
	isManagedRuleCurrent,
	removeManagedEntries,
	syncManagedEntries,
} from '../cli/lib/karabiner.mjs';

test('Fn rule preserves modifier combinations and only toggles on a standalone tap', async () => {
	const template = JSON.parse(await readFile(new URL('../karabiner/dji-mic-mini.json', import.meta.url), 'utf8'));
	const fn = template.rules[0].manipulators.find((item) => item.from?.key_code === 'fn');
	assert.ok(fn);
	assert.deepEqual(fn.from, { key_code: 'fn' });
	assert.deepEqual(fn.to, [{ key_code: 'fn', lazy: true }]);
	assert.deepEqual(fn.to_if_alone, [{ shell_command: '~/.config/karabiner/scripts/speek-command toggle fn' }]);
});

const templateRule = {
	description: 'SpeekCoding: Fn or DJI Mic Mini toggles native dictation',
	manipulators: [
		{
			from: { key_code: 'fn' },
			to_if_alone: [
				{ shell_command: '/Users/Test/.config/karabiner/scripts/speek-command toggle fn' },
			],
			type: 'basic',
		},
	],
};

const legacyRule = {
	description: 'Fn dictation toggle + confirm/preconfirm to send Enter',
	manipulators: [
		{
			from: { key_code: 'fn' },
			to_if_alone: [
				{
					shell_command:
						'/Users/Test/.config/karabiner/scripts/speek-recorder route fn-save save 2>/dev/null',
				},
			],
			type: 'basic',
		},
	],
};

function createConfig(rules) {
	return {
		profiles: [
			{
				name: 'Default profile',
				selected: true,
				complex_modifications: { rules: structuredClone(rules) },
				devices: [],
			},
		],
	};
}

test('absolute legacy recorder rules make the managed profile non-current', () => {
	const config = createConfig([legacyRule, templateRule]);
	assert.equal(isManagedRuleCurrent(config.profiles[0], templateRule), false);
});

test('sync removes absolute legacy rules and leaves exactly one current rule', () => {
	const unrelatedRule = { description: 'Keep me', manipulators: [] };
	const config = createConfig([unrelatedRule, legacyRule, templateRule]);

	syncManagedEntries(config, templateRule, 'Default profile', { includeManagedDevice: false });

	assert.deepEqual(
		config.profiles[0].complex_modifications.rules.map((rule) => rule.description),
		['Keep me', templateRule.description],
	);
	assert.equal(isManagedRuleCurrent(config.profiles[0], templateRule), true);
});

test('removeManagedEntries recognizes an absolute legacy dictation script path', () => {
	const config = createConfig([
		{
			description: 'Older Speek workflow',
			manipulators: [
				{
					to: [
						{
							shell_command:
								'/Users/Another/.config/karabiner/scripts/dictation-enter.sh save',
						},
					],
				},
			],
		},
	]);

	const result = removeManagedEntries(config, templateRule);

	assert.equal(result.removedRuleCount, 1);
	assert.equal(config.profiles[0].complex_modifications.rules.length, 0);
});
