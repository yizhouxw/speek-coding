import assert from 'node:assert/strict';
import test from 'node:test';
import { buildReleaseNotes } from '../scripts/release-notes.mjs';

test('release notes require the matching stable version tag', () => {
	const changelog = '## [1.2.3] - 2026-11-03\n\nChanges.\n\n## [1.2.2]\n\nOld.\n';
	assert.equal(buildReleaseNotes('1.2.3', 'v1.2.3', changelog), 'Changes.\n');
	assert.throws(() => buildReleaseNotes('1.2.3', 'v1.2.2', changelog), /Release tag/u);
	assert.throws(() => buildReleaseNotes('1.2.3', 'v1.2.3-rc.1', changelog), /Release tag/u);
});

test('release notes reject missing or empty changelog sections', () => {
	assert.throws(() => buildReleaseNotes('1.2.3', 'v1.2.3', '## [1.2.2]\nOld'), /nonempty/u);
	assert.throws(() => buildReleaseNotes('1.2.3', 'v1.2.3', '## [1.2.3]\n\n## [1.2.2]\nOld'), /nonempty/u);
});
