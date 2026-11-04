import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { sendAgentCommand } from '../cli/lib/agent.mjs';

async function withAgentServer(context, responder) {
	const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'speek-agent-test-'));
	const socketPath = path.join(directory, 'agent.sock');
	const server = net.createServer((socket) => {
		let input = '';
		socket.setEncoding('utf-8');
		socket.on('data', (chunk) => {
			input += chunk;
			const newline = input.indexOf('\n');
			if (newline === -1) return;
			const request = JSON.parse(input.slice(0, newline));
			socket.end(`${JSON.stringify(responder(request))}\n`);
		});
	});
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(socketPath, resolve);
	});
	await fs.chmod(socketPath, 0o600);
	context.after(async () => {
		await new Promise((resolve) => server.close(resolve));
		await fs.rm(directory, { recursive: true, force: true });
	});
	return { agentSocketPath: socketPath };
}

test('sendAgentCommand exchanges newline-delimited JSON over the app socket', async (context) => {
	const runtime = await withAgentServer(context, (request) => ({
		ok: true,
		command: request.command,
		state: 'idle',
		bundleIdentifier: 'com.speek.coding',
	}));
	const response = await sendAgentCommand(runtime, { command: 'ping' }, { launch: false });
	assert.equal(response.ok, true);
	assert.equal(response.bundleIdentifier, 'com.speek.coding');
});

test('sendAgentCommand preserves native app error codes', async (context) => {
	const runtime = await withAgentServer(context, () => ({
		ok: false,
		error: { code: 'MICROPHONE_PERMISSION_REQUIRED', message: 'Allow SpeekCoding.' },
	}));
	await assert.rejects(
		sendAgentCommand(runtime, { command: 'save' }, { launch: false }),
		(error) => error.code === 'MICROPHONE_PERMISSION_REQUIRED' && error.message === 'Allow SpeekCoding.',
	);
});

test('sendAgentCommand attaches the private IPC credential', async (context) => {
	let receivedRequest;
	const runtime = await withAgentServer(context, (request) => {
		receivedRequest = request;
		return { ok: true, command: request.command, state: 'idle' };
	});
	runtime.ipcTokenPath = path.join(path.dirname(runtime.agentSocketPath), 'ipc-token');
	const token = 'a'.repeat(64);
	await fs.writeFile(runtime.ipcTokenPath, `${token}\n`, { mode: 0o600 });
	await sendAgentCommand(runtime, { command: 'status' }, { launch: false });
	assert.equal(receivedRequest.token, token);
});

test('sendAgentCommand rejects a non-private socket directory before connecting', async (context) => {
	const runtime = await withAgentServer(context, () => ({ ok: true, command: 'status', state: 'idle' }));
	await fs.chmod(path.dirname(runtime.agentSocketPath), 0o755);
	await assert.rejects(
		sendAgentCommand(runtime, { command: 'status' }, { launch: false }),
		(error) => error.code === 'AGENT_SOCKET_UNSAFE',
	);
});
