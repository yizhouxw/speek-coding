import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
const identifier = 'com.speek.coding';
const inside = (child, parent) => child === parent || child.startsWith(`${parent}${path.sep}`);

export function registeredApps(dump) {
	const paths = new Set();
	let candidate;
	for (const line of dump.split('\n')) {
		if (line.startsWith('path:')) candidate = line.slice(5).trim().replace(/ \(0x[\da-f]+\)$/iu, '');
		if (line.startsWith('identifier:') && line.slice(11).trim() === identifier && candidate) paths.add(candidate);
	}
	return paths;
}

// Called only after the replacement app passes its health check and settings are saved.
// Never sweep user data directories or reset the global Launch Services database.
export async function cleanupOldApps(runtime, config, { run = execute, applicationRoots } = {}) {
	const result = { removed: [], unregistered: [], warnings: [] };
	if (runtime.env.SPEEK_SKIP_AGENT_HEALTHCHECK === '1' || runtime.env.SPEEK_SKIP_LAUNCHSERVICES_REGISTER === '1') return result;
	try {
		const current = await fs.realpath(runtime.speekCodingAppTargetPath);
		const { stdout } = await run(register, ['-dump'], { env: runtime.env, maxBuffer: 32 * 1024 * 1024 });
		const registered = registeredApps(stdout);
		const candidates = new Set(registered);
		const roots = applicationRoots || [path.join(runtime.homeDir, 'Applications'), '/Applications'];
		for (const root of roots) {
			for (const name of await fs.readdir(root).catch(() => [])) {
				if (/^SpeekCoding(?:[-.].*)?\.app$/u.test(name)) candidates.add(path.join(root, name));
			}
		}
		for (const arch of ['arm64', 'x86_64']) {
			candidates.add(path.join(runtime.repoRoot, 'build', `package-${arch}`, 'root/Applications/SpeekCoding.app'));
		}
		const protectedPaths = [current, runtime.configDir, runtime.venvDir, config.pythonBin,
			path.join(runtime.homeDir, '.cache/huggingface'),
			runtime.env.HF_HOME, runtime.env.HF_HUB_CACHE, runtime.env.HUGGINGFACE_HUB_CACHE,
			runtime.env.TRANSFORMERS_CACHE, runtime.env.XDG_CACHE_HOME].filter(Boolean);
		const protectedReal = await Promise.all(protectedPaths.map(async p => fs.realpath(p).catch(() => path.resolve(p))));
		const processes = (await run('/bin/ps', ['-axo', 'comm='], { env: runtime.env })).stdout.split('\n').map(p => p.trim());
		for (const candidate of candidates) {
			try {
				const absolute = path.resolve(candidate);
				const stat = await fs.lstat(absolute).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
				if (!stat && !registered.has(absolute)) continue;
				const real = stat ? await fs.realpath(absolute) : absolute;
				if (protectedReal.some(p => inside(p, real) || inside(real, p))) continue;
				if (processes.some(p => inside(p, real))) {
					result.warnings.push(`Still running; kept ${absolute}`);
					continue;
				}
				if (stat) {
					const { stdout: info } = await run('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', path.join(real, 'Contents/Info.plist')]);
					if (info.trim() !== identifier) continue;
				}
				await run(register, ['-u', absolute], { env: runtime.env });
				result.unregistered.push(absolute);
				// Delete only recognized installed copies and generated package apps.
				const installedCopy = roots.some(root => path.dirname(absolute) === root);
				const buildCopy = inside(absolute, runtime.homeDir) && /\/build\/package-(arm64|x86_64)\/root\/Applications\/SpeekCoding\.app$/u.test(absolute);
				if (stat?.isDirectory() && real === absolute && (installedCopy || buildCopy)) {
					await fs.rm(absolute, { recursive: true });
					result.removed.push(absolute);
				}
			} catch (error) {
				result.warnings.push(`${candidate}: ${error.message}`);
			}
		}
		await run(register, ['-gc'], { env: runtime.env });
		await run(register, ['-f', current], { env: runtime.env });
	} catch (error) {
		result.warnings.push(error.message);
	}
	return result;
}
