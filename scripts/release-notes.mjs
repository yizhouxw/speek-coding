import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

export function buildReleaseNotes(version, tag, changelog) {
	if (!/^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/u.test(tag) || tag !== `v${version}`) {
		throw new Error(`Release tag must be v${version} and use a stable x.y.z version.`);
	}
	const escaped = version.replaceAll('.', '\\.');
	const match = changelog.match(new RegExp(`^## \\[${escaped}\\][^\\n]*\\n([\\s\\S]*?)(?=^## |$(?![\\s\\S]))`, 'm'));
	if (!match || !match[1].trim()) {
		throw new Error(`CHANGELOG.md must contain a nonempty [${version}] release section.`);
	}
	return `${match[1].trim()}\n`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	const version = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;
	const changelog = fs.readFileSync(new URL('../CHANGELOG.md', import.meta.url), 'utf8');
	process.stdout.write(buildReleaseNotes(version, process.argv[2] || '', changelog));
}
