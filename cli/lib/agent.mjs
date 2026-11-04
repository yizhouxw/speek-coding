import { execFile as execFileCallback } from 'node:child_process';
import fs from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);

function createAgentError(message, code, cause) {
	const error = new Error(message);
	error.code = code;
	if (cause) {
		error.cause = cause;
	}
	return error;
}

async function pathExists(filePath) {
	try {
		await fs.access(filePath);
		return true;
	} catch {
		return false;
	}
}

function requestOverSocket(socketPath, payload, timeoutMs) {
	return new Promise((resolve, reject) => {
		let settled = false;
		let response = '';
		const socket = net.createConnection({ path: socketPath });
		const timer = setTimeout(() => {
			if (settled) return;
			settled = true;
			socket.destroy();
			reject(createAgentError(`SpeekCoding did not respond within ${timeoutMs}ms.`, 'AGENT_TIMEOUT'));
		}, timeoutMs);

		function finish(error, result) {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			socket.destroy();
			if (error) reject(error);
			else resolve(result);
		}

		socket.setEncoding('utf-8');
		socket.on('connect', () => socket.end(`${JSON.stringify(payload)}\n`));
		socket.on('data', (chunk) => {
			response += chunk;
			const newline = response.indexOf('\n');
			if (newline === -1) return;
			const line = response.slice(0, newline).trim();
			try {
				const parsed = JSON.parse(line);
				if (!parsed.ok) {
					const errorPayload = parsed.error;
					const message =
						typeof errorPayload === 'string'
							? errorPayload
							: errorPayload?.message || 'SpeekCoding command failed.';
					const code = parsed.code || errorPayload?.code || 'AGENT_COMMAND_FAILED';
					finish(createAgentError(message, code));
					return;
				}
				finish(null, parsed);
			} catch (error) {
				finish(createAgentError(`Invalid SpeekCoding response: ${line}`, 'AGENT_INVALID_RESPONSE', error));
			}
		});
		socket.on('error', (error) => finish(createAgentError(error.message, error.code || 'AGENT_CONNECTION_FAILED', error)));
		socket.on('end', () => {
			if (!settled && !response.includes('\n')) {
				finish(createAgentError('SpeekCoding closed the IPC connection without a response.', 'AGENT_EMPTY_RESPONSE'));
			}
		});
	});
}

async function validateSocketLocation(runtime) {
	const expectedUserID = Number(runtime.uid ?? (typeof process.getuid === 'function' ? process.getuid() : -1));
	const directoryPath = path.dirname(runtime.agentSocketPath);
	let directory;
	try {
		directory = await fs.lstat(directoryPath);
	} catch (error) {
		if (error.code === 'ENOENT') return;
		throw createAgentError(`Could not inspect ${directoryPath}.`, 'AGENT_SOCKET_UNSAFE', error);
	}
	if (
		directory.isSymbolicLink() ||
		!directory.isDirectory() ||
		directory.uid !== expectedUserID ||
		(directory.mode & 0o077) !== 0
	) {
		throw createAgentError(
			`SpeekCoding IPC directory is not a private directory owned by the current user: ${directoryPath}.`,
			'AGENT_SOCKET_UNSAFE',
		);
	}
	try {
		const socket = await fs.lstat(runtime.agentSocketPath);
		if (
			socket.isSymbolicLink() ||
			!socket.isSocket() ||
			socket.uid !== expectedUserID ||
			(socket.mode & 0o077) !== 0
		) {
			throw createAgentError(
				`SpeekCoding IPC endpoint is not a private socket owned by the current user: ${runtime.agentSocketPath}.`,
				'AGENT_SOCKET_UNSAFE',
			);
		}
	} catch (error) {
		if (error.code === 'ENOENT') return;
		if (error.code === 'AGENT_SOCKET_UNSAFE') throw error;
		throw createAgentError(`Could not inspect ${runtime.agentSocketPath}.`, 'AGENT_SOCKET_UNSAFE', error);
	}
}

async function requestAgent(runtime, payload, timeoutMs) {
	await validateSocketLocation(runtime);
	return requestOverSocket(runtime.agentSocketPath, payload, timeoutMs);
}

async function authenticatedPayload(runtime, payload) {
	if (!runtime.ipcTokenPath || payload.token) return payload;
	try {
		const token = (await fs.readFile(runtime.ipcTokenPath, 'utf-8')).trim();
		return token ? { ...payload, token } : payload;
	} catch (error) {
		if (error.code === 'ENOENT') return payload;
		throw createAgentError('Could not read the SpeekCoding IPC credential.', 'AGENT_CREDENTIAL_UNREADABLE', error);
	}
}

async function pingAgent(runtime, timeoutMs = 500) {
	try {
		const payload = await authenticatedPayload(runtime, { command: 'ping' });
		const response = await requestAgent(runtime, payload, timeoutMs);
		if (response.bundleIdentifier !== 'com.speek.coding' || response.protocolVersion !== 1) {
			throw createAgentError(
				`Unexpected IPC peer at ${runtime.agentSocketPath}.`,
				'AGENT_IDENTITY_MISMATCH',
			);
		}
		return response;
	} catch (error) {
		if (['AGENT_IDENTITY_MISMATCH', 'AGENT_SOCKET_UNSAFE', 'IPC_UNAUTHORIZED'].includes(error.code)) {
			throw error;
		}
		return null;
	}
}

export async function launchAgent(runtime, { timeoutMs = 6000 } = {}) {
	if (!(await pathExists(runtime.speekCodingAppTargetPath))) {
		throw createAgentError(
			`SpeekCoding.app is not installed at ${runtime.speekCodingAppTargetPath}. Run \`speek update\` first.`,
			'AGENT_APP_MISSING',
		);
	}
	const existing = await pingAgent(runtime);
	if (existing) {
		return existing;
	}
	await execFile('/usr/bin/open', ['-gj', runtime.speekCodingAppTargetPath], { env: runtime.env });
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		await new Promise((resolve) => setTimeout(resolve, 120));
		const response = await pingAgent(runtime);
		if (response) {
			return response;
		}
	}
	throw createAgentError(
		`SpeekCoding.app did not create ${runtime.agentSocketPath}.`,
		'AGENT_START_FAILED',
	);
}

export async function sendAgentCommand(runtime, payload, { timeoutMs = 660000, launch = true } = {}) {
	if (launch) {
		await launchAgent(runtime);
	}
	return requestAgent(runtime, await authenticatedPayload(runtime, payload), timeoutMs);
}

export async function getAgentStatus(runtime, { launch = false } = {}) {
	if (launch) {
		try {
			await launchAgent(runtime);
		} catch (error) {
			return { installed: await pathExists(runtime.speekCodingAppTargetPath), running: false, error: error.code };
		}
	}
	try {
		const response = await pingAgent(runtime);
		return {
			installed: await pathExists(runtime.speekCodingAppTargetPath),
			running: Boolean(response),
			response,
		};
	} catch (error) {
		return {
			installed: await pathExists(runtime.speekCodingAppTargetPath),
			running: false,
			response: null,
			error: error.code || 'AGENT_STATUS_FAILED',
		};
	}
}
