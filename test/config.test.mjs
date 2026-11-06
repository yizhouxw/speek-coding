import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { DEFAULT_CONFIG, QWEN_MODEL, loadConfig, normalizeConfig, writeConfig } from '../cli/lib/config.mjs';
import { mergeConfig } from '../cli/lib/actions.mjs';

test('normalizeConfig validates service settings', () => {
	assert.equal(DEFAULT_CONFIG.asrBeamSize, 3);
	const config = normalizeConfig({
		asrBackend: 'WHISPER-CPP',
		asrPort: '9000',
		asrBestOf: '3',
		asrVadFilter: 'off',
	});
	assert.equal(config.asrBackend, 'whisper-cpp');
	assert.equal(config.asrPort, 9000);
	assert.equal(config.asrBestOf, 3);
	assert.equal(config.asrVadFilter, false);
	assert.equal(normalizeConfig({ asrLanguage: 'auto' }).asrLanguage, '');
	assert.equal(normalizeConfig({ asrLanguage: 'zh' }).asrLanguage, 'zh');
	assert.equal(normalizeConfig({ asrPort: '3.5' }).asrPort, DEFAULT_CONFIG.asrPort);
	assert.equal(normalizeConfig({ asrHost: '0.0.0.0' }).asrHost, DEFAULT_CONFIG.asrHost);
});

test('switching local engines selects a matching model and preserves explicit choices', () => {
	const qwen = mergeConfig({ ...DEFAULT_CONFIG, asrBackend: 'faster-whisper', asrModel: 'turbo' }, { asrBackend: 'qwen-mlx' });
	assert.equal(qwen.asrModel, QWEN_MODEL);
	assert.equal(qwen.asrStreaming, true);
	assert.equal(normalizeConfig({ asrBackend: 'faster-whisper' }).asrModel, 'whisper-large-v3-turbo');
	assert.equal(normalizeConfig({ asrBackend: 'qwen-mlx' }).asrModel, QWEN_MODEL);
	assert.equal(mergeConfig(qwen, { asrBackend: 'faster-whisper' }).asrModel, 'whisper-large-v3-turbo');
	assert.equal(mergeConfig(qwen, { asrBackend: 'whisper-cpp', asrModel: '/tmp/model.bin' }).asrModel, '/tmp/model.bin');
});

test('loadConfig migrates legacy DJI preferences', async (context) => {
	const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'speek-config-'));
	context.after(() => fs.rm(directory, { recursive: true, force: true }));
	const configFilePath = path.join(directory, 'config.env');
	await fs.writeFile(
		configFilePath,
		[
			'DJI_ENABLE_AUDIO_FEEDBACK=0',
			"DJI_PRECONFIRM_SOUND_NAME=''",
			'DJI_ENABLE_READY_HUD=0',
			'DJI_REVIEW_WINDOW_SECONDS=5',
		].join('\n'),
		'utf-8',
	);
	const config = await loadConfig({ configFilePath });
	assert.equal(config.audioFeedbackEnabled, false);
	assert.equal(config.readyOverlayEnabled, false);
	assert.equal(config.reviewWindowSeconds, 5);
});

test('writeConfig emits canonical SPEEK preferences', async (context) => {
	const configDir = await fs.mkdtemp(path.join(os.tmpdir(), 'speek-config-'));
	context.after(() => fs.rm(configDir, { recursive: true, force: true }));
	const configFilePath = path.join(configDir, 'config.env');
	await writeConfig({ configDir, configFilePath }, { ...DEFAULT_CONFIG, asrBackend: 'whisper-cpp' });
	const content = await fs.readFile(configFilePath, 'utf-8');
	const directoryMode = (await fs.stat(configDir)).mode & 0o777;
	const fileMode = (await fs.stat(configFilePath)).mode & 0o777;
	assert.match(content, /SPEEK_AUDIO_FEEDBACK_ENABLED=1/u);
	assert.match(content, /SPEEK_ASR_BACKEND='whisper-cpp'/u);
	assert.match(content, /SPEEK_ASR_LANGUAGE=''/u);
	assert.doesNotMatch(content, /DJI_ENABLE_AUDIO_FEEDBACK/u);
	assert.equal(directoryMode, 0o700);
	assert.equal(fileMode, 0o600);
});

test('local server port changes keep the transcription endpoint in sync', () => {
	const config = mergeConfig(DEFAULT_CONFIG, { asrHost: '0.0.0.0', asrPort: 9100 });
	assert.equal(config.asrHost, '127.0.0.1');
	assert.equal(config.asrApiUrl, 'http://127.0.0.1:9100/v1/audio/transcriptions');
});
