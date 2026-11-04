import assert from 'node:assert/strict';
import { execFile as execFileCallback } from 'node:child_process';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const serverPath = path.join(repoRoot, 'scripts', 'local-asr-server.py');

async function evaluatePython(expression, args = []) {
	const script = `
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("speek_local_asr_server", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(json.dumps(${expression}))
`;
	const { stdout } = await execFile('python3', ['-c', script, serverPath, ...args]);
	return JSON.parse(stdout);
}

async function buildWhisperCommand(language) {
	const script = `
import importlib.util
import json
import pathlib
import sys
import types

spec = importlib.util.spec_from_file_location("speek_local_asr_server", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
args = types.SimpleNamespace(
    whisper_cpp_bin="/tmp/whisper-cli",
    beam_size=1,
    best_of=1,
    cpu_threads=8,
)
language = None if sys.argv[2] == "__none__" else sys.argv[2]
command = module.build_whisper_cpp_command(
    args,
    pathlib.Path("/tmp/input.wav"),
    pathlib.Path("/tmp/model.bin"),
    language,
    "mixed prompt",
)
print(json.dumps(command))
`;
	const { stdout } = await execFile('python3', [
		'-c',
		script,
		serverPath,
		language ?? '__none__',
	]);
	return JSON.parse(stdout);
}

test('whisper.cpp command uses auto detection when language is unset', async () => {
	const command = await buildWhisperCommand(null);
	const languageIndex = command.indexOf('-l');
	assert.notEqual(languageIndex, -1);
	assert.equal(command[languageIndex + 1], 'auto');
});

test('whisper.cpp command preserves an explicit language', async () => {
	const command = await buildWhisperCommand('zh');
	const languageIndex = command.indexOf('-l');
	assert.equal(command[languageIndex + 1], 'zh');
});

test('local ASR only accepts loopback bind addresses', async () => {
	const result = await evaluatePython('[module.is_loopback_host(value) for value in sys.argv[2:]]', [
		'localhost',
		'127.0.0.1',
		'127.9.8.7',
		'::1',
		'0.0.0.0',
		'192.168.1.10',
		'example.com',
	]);
	assert.deepEqual(result, [true, true, true, true, false, false, false]);
});

test('local ASR rejects per-request model overrides', async () => {
	const accepted = await evaluatePython('module.select_model("whisper-large-v3-turbo", "turbo")');
	assert.equal(accepted, 'whisper-large-v3-turbo');

	await assert.rejects(
		evaluatePython('module.select_model("tiny", "large-v3")'),
		(error) => error.code === 1 && /model overrides/u.test(error.stderr),
	);
});

test('local ASR enforces its request size limit before reading an upload', async () => {
	const accepted = await evaluatePython('module.parse_content_length("1024", 1024)');
	assert.equal(accepted, 1024);

	await assert.rejects(
		evaluatePython('module.parse_content_length("1025", 1024)'),
		(error) => error.code === 1 && /configured limit/u.test(error.stderr),
	);
});

test('canceling a model download terminates its worker and resets the phase', async () => {
	const script = `
import importlib.util, sys, types
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('server', sys.argv[1])
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
fake = types.ModuleType('faster_whisper')
fake.WhisperModel = lambda *args, **kwargs: None
utils = types.ModuleType('faster_whisper.utils')
def missing(*args, **kwargs): raise FileNotFoundError('not cached')
utils.download_model = missing
class Process:
    returncode = None
    terminated = False
    def poll(self): return self.returncode
    def terminate(self): self.terminated = True; self.returncode = -15
    def wait(self, timeout=None): return self.returncode
    def kill(self): self.returncode = -9
worker = Process()
cache = server.ModelCache('cpu', 'int8', 0)
def disconnected():
    assert cache.phase == 'downloading'
    return True
with patch.dict(sys.modules, {'faster_whisper': fake, 'faster_whisper.utils': utils}), patch.object(server.subprocess, 'Popen', return_value=worker) as popen:
    try: cache.get('turbo', disconnected)
    except ConnectionAbortedError: pass
    else: raise AssertionError('download was not canceled')
assert worker.terminated and cache.phase == 'idle'
assert popen.call_args.args[0][1] == '-B'
`;
	await execFile('python3', ['-c', script, serverPath]);
});
