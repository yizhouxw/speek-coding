"""Exercise the real HTTP/session protocol without downloading ML weights."""
import concurrent.futures
import importlib.util
import json
import pathlib
import math
import struct
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import wave

spec = importlib.util.spec_from_file_location("asr", pathlib.Path(__file__).parents[1] / "scripts/local-asr-server.py")
asr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asr)


class FakeSession:
    def __init__(self):
        self.calls = []

    def init_streaming(self, **options):
        self.calls.append(("start", threading.get_ident(), options))
        return types.SimpleNamespace(text="", bytes=b"")

    def feed_audio(self, audio, state):
        self.calls.append(("append", threading.get_ident(), audio))
        state.bytes += audio
        # A revision must replace the earlier draft, not concatenate it.
        state.text = "同义词" if len(state.bytes) == 2 else "同音词"
        return state

    def finish_streaming(self, state):
        self.calls.append(("finish", threading.get_ident(), state.bytes))
        state.text += "。"
        return state


class StreamingTests(unittest.TestCase):
    def setUp(self):
        self.engine = asr.QwenEngine(asr.QWEN_MODEL)
        self.fake = FakeSession()
        self.engine.session = self.fake
        self.engine.decode_pcm = lambda data: data
        args = types.SimpleNamespace(backend="qwen-mlx", model=asr.QWEN_MODEL, quiet=True, max_request_bytes=1024 * 1024)
        self.server = asr.ThreadingHTTPServer(("127.0.0.1", 0), asr.make_handler(args, self.engine))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1/audio/streams"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.engine.worker.shutdown()

    def post(self, suffix="", body=b"{}", content_type="application/json", sequence=0, **headers):
        request = urllib.request.Request(self.url + suffix, data=body, headers={
            "Content-Type": content_type, "X-Speek-Sequence": str(sequence), **headers,
        })
        with self.opener.open(request, timeout=5) as response:
            return json.load(response)

    def error(self, code, *args, **kwargs):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)
        caught.exception.close()

    def test_local_models_reject_origins_and_switch_only_when_idle(self):
        self.url = self.url.replace('/audio/streams', '/models/select')
        data = json.dumps({'model': asr.QWEN_MODEL}).encode()
        self.error(403, body=data, Origin='https://example.com')
        self.error(400, body=b'{"model":"unknown"}')
        self.error(400, body=b'{"model":[]}')
        self.error(400, body=b'{')
        with patch.object(asr.LocalTextModel, 'model_path', return_value='/cached'):
            self.assertTrue(self.post(body=data)['ok'])
            self.engine.streams['active'] = {}
            self.error(409, body=data)

    def test_prepare_reports_readiness_and_rejects_browser_origins(self):
        url = self.url.replace("/streams", "/prepare")
        request = urllib.request.Request(url, data=b"", method="POST")
        with self.opener.open(request, timeout=5) as response:
            self.assertTrue(json.load(response)["model_ready"])
        request.add_header("Origin", "https://example.com")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.opener.open(request, timeout=5)
        self.assertEqual(caught.exception.code, 403)
        caught.exception.close()
        # Initialization executes on the same owner thread as inference.
        self.engine.session = None
        owner = []
        def load(disconnected):
            owner.append(threading.get_ident())
            self.engine.session = self.fake
            return self.fake
        self.engine.get = load
        request = urllib.request.Request(url, data=b"", method="POST")
        with self.opener.open(request, timeout=5) as response:
            self.assertTrue(json.load(response)["model_ready"])
        self.assertNotEqual(owner[0], threading.get_ident())

    def test_cpp_preparation_is_once_per_service_and_retries_failures(self):
        args = types.SimpleNamespace(backend="whisper-cpp", model="test.bin", quiet=True,
                                     max_request_bytes=1024)
        cache = asr.ModelCache("cpu", "int8", 0)
        server = asr.ThreadingHTTPServer(("127.0.0.1", 0), asr.make_handler(args, cache))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        def ready():
            with self.opener.open(base + "/health") as response:
                return json.load(response)["model_ready"]
        def prepare():
            with self.opener.open(urllib.request.Request(base + "/v1/audio/prepare", data=b"")) as response:
                return json.load(response)
        try:
            self.assertFalse(ready())
            with patch.object(asr, "transcribe_whisper_cpp", side_effect=RuntimeError("load failed")):
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    prepare()
                self.assertEqual(caught.exception.code, 503)
                caught.exception.close()
            self.assertFalse(ready())
            self.assertEqual(cache.phase, "idle")
            def warm(args, path, *unused):
                self.assertEqual(cache.phase, "loading")
                with wave.open(str(path)) as audio:
                    self.assertEqual(audio.getnframes(), 16000)
                return "", None, None
            with patch.object(asr, "transcribe_whisper_cpp", side_effect=warm) as inference:
                self.assertTrue(prepare()["model_ready"])
                self.assertTrue(ready())
                prepare()
                self.assertEqual(inference.call_count, 1)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_revisions_final_tail_and_single_thread_ownership(self):
        session = self.post(body=json.dumps({"language": "zh"}).encode())["id"]
        suffix = f"/{session}"
        self.assertEqual(self.post(suffix + "/append", b"\x01\x02", "application/octet-stream")["text"], "同义词")
        self.assertEqual(self.post(suffix + "/append", b"\x03\x04", "application/octet-stream", 1)["text"], "同音词")
        final = self.post(suffix + "/finish", b"\0", "application/octet-stream", 2)
        self.assertEqual(final["text"], "同音词。")
        self.assertTrue(final["is_final"])
        self.assertEqual(self.fake.calls[-1][-1], b"\x01\x02\x03\x04")
        self.assertEqual(len({call[1] for call in self.fake.calls}), 1)
        self.assertNotEqual(self.fake.calls[0][1], threading.get_ident())
        self.assertEqual(self.fake.calls[0][2]["language"], "Chinese")
        self.error(404, suffix + "/append", b"\0\0", "application/octet-stream", 3)
        self.assertFalse(self.engine.streams)

    def test_invalid_requests_do_not_consume_or_reorder_audio(self):
        self.error(403, Origin="https://example.com")
        self.error(400, body=b"[]")
        self.error(400, body=b'{"sample_rate":48000}')
        self.error(400, body=b'{"model":"other-model"}')
        session = self.post()["id"]
        self.error(409)
        suffix = f"/{session}/append"
        self.error(415, suffix, b"\0\0")
        self.error(409, suffix, b"\0\0", "application/octet-stream", 1)
        self.error(400, suffix, b"\0", "application/octet-stream")
        self.error(413, suffix, b"\0" * (asr.STREAM_CHUNK_BYTES + 2), "application/octet-stream")
        self.assertEqual(len(self.fake.calls), 1)
        self.post(f"/{session}/cancel")
        self.assertFalse(self.engine.streams)
        self.post()  # Cancellation permits the next recording immediately.

    def test_expiry_limits_and_failed_inference_release_state(self):
        session = self.post()["id"]
        item = self.engine.streams[session]
        item["touched"] -= 31
        self.error(408, f"/{session}/append", b"\0\0", "application/octet-stream")
        session = self.post()["id"]
        self.engine.streams[session]["bytes"] = asr.STREAM_MAX_BYTES
        self.error(413, f"/{session}/append", b"\0\0", "application/octet-stream")
        session = self.post()["id"]
        def fail(*_):
            raise RuntimeError("inference failed")
        self.fake.feed_audio = fail
        self.error(500, f"/{session}/append", b"\0\0", "application/octet-stream")
        self.assertFalse(self.engine.streams)

    def test_configured_model_identifier_is_not_treated_as_a_local_path(self):
        self.assertEqual(asr.normalize_model_name(asr.QWEN_MODEL), asr.QWEN_MODEL)
        self.assertEqual(asr.select_model(asr.QWEN_MODEL, ""), asr.QWEN_MODEL)

    def test_cached_warmup_never_downloads_and_cancel_stops_first_download(self):
        hub = types.ModuleType("huggingface_hub")
        def missing(*_, **options):
            self.assertTrue(options["local_files_only"])
            raise FileNotFoundError("not cached")
        hub.snapshot_download = missing
        mlx = types.ModuleType("mlx_qwen3_asr")
        mlx.Session = lambda **_: self.fake
        self.engine.session = None

        class Process:
            returncode = None
            terminated = False
            def poll(self): return self.returncode
            def terminate(self): self.terminated = True; self.returncode = -15
            def wait(self, timeout=None): return self.returncode
            def kill(self): self.returncode = -9

        process = Process()
        def disconnected():
            self.assertEqual(self.engine.phase, "downloading")
            return True
        with patch.dict(sys.modules, {"huggingface_hub": hub, "mlx_qwen3_asr": mlx}), patch.object(asr.subprocess, "Popen", return_value=process) as spawn:
            self.engine.run(self.engine.warm_cached)
            spawn.assert_not_called()
            with self.assertRaises(ConnectionAbortedError):
                self.engine.run(self.engine.get, disconnected)
            self.assertTrue(process.terminated)
            self.assertEqual(self.engine.phase, "idle")
            self.assertIsNone(self.engine.session)
            self.assertEqual(spawn.call_args.args[0][1], "-B")


if __name__ == "__main__":
    if "--native-client" in sys.argv:
        index = sys.argv.index("--native-client")
        native_client = sys.argv[index + 1]
        del sys.argv[index:index + 2]

        def native_replay(self):
            with tempfile.TemporaryDirectory() as directory:
                path = pathlib.Path(directory) / "synthetic.wav"
                with wave.open(str(path), "wb") as audio:
                    audio.setnchannels(1)
                    audio.setsampwidth(2)
                    audio.setframerate(16000)
                    audio.writeframes(b"".join(struct.pack("<h", int(2000 * math.sin(i * 0.1))) for i in range(22000)))
                base = self.url.replace("/streams", "/transcriptions")
                command = [native_client, "--streaming-self-test", base, asr.QWEN_MODEL, str(path)]
                output = subprocess.check_output(command, text=True, timeout=15)
                events = [json.loads(line) for line in output.splitlines()]
                self.assertTrue(events[-1]["ok"])
                self.assertEqual(events[-1]["final"], "同音词。")
                self.assertTrue(any("partial" in event for event in events[:-1]))
                self.assertFalse(self.engine.streams)
                output = subprocess.check_output(command + ["--cancel"], text=True, timeout=15)
                self.assertTrue(json.loads(output.splitlines()[-1])["ok"])
                self.assertFalse(self.engine.streams)
            # A completed/canceled client's callbacks must not hold the next recording.
            self.post()

        StreamingTests.test_native_replay_and_cancel = native_replay
    unittest.main()
