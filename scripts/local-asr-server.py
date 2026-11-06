#!/usr/bin/env python3
from __future__ import annotations

import argparse
import cgi
import ipaddress
import json
import os
import platform
import re
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse


MODEL_ALIASES = {
    "whisper-large-v3-turbo": "turbo",
    "large-v3-turbo": "turbo",
    "whisper-turbo": "turbo",
}

DEFAULT_MAX_REQUEST_BYTES = 256 * 1024 * 1024
MAX_MODEL_LENGTH = 512
MAX_LANGUAGE_LENGTH = 64
MAX_PROMPT_LENGTH = 16 * 1024
QWEN_MODEL = "mlx-community/Qwen3-ASR-0.6B-4bit"
QWEN_REVISION = "313d850181767edf09f00a9c289becca70e58cd0"
# Longer accumulated prefixes repeated whole sentences in the 44-second replay.
# Keep bounded windows and let the adapter commit near a pause before continuing.
QWEN_CONTEXT_SECONDS = 20.0
STREAM_MAX_BYTES = 300 * 16000 * 2
STREAM_CHUNK_BYTES = 64000


class ClientRequestError(ValueError):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


def is_loopback_host(host: str) -> bool:
    normalized = (host or "").strip().lower()
    if normalized == "localhost":
        return True
    if normalized.startswith("[") and normalized.endswith("]"):
        normalized = normalized[1:-1]
    try:
        return ipaddress.ip_address(normalized).is_loopback
    except ValueError:
        return False


def normalize_model_name(model_name: str) -> str:
    raw = (model_name or "turbo").strip()
    if raw == QWEN_MODEL:
        return raw
    if "/" in raw or raw.startswith(".") or raw.startswith("~"):
        return os.path.abspath(os.path.expanduser(raw))
    return MODEL_ALIASES.get(raw, raw)


class QwenEngine:
    """One owner thread for both loading and all Metal inference operations."""

    def __init__(self, model_name: str):
        self.model_name = model_name
        self.phase = "idle"
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="speek-mlx")
        self.session = None
        self.streams = {}

    def run(self, method, *args):
        return self.worker.submit(method, *args).result()

    def warm_cached(self):
        """Prepare cached weights at service startup; first-use downloads stay cancellable."""
        try:
            if not Path(os.path.expanduser(self.model_name)).is_dir():
                from huggingface_hub import snapshot_download
                snapshot_download(self.model_name,
                                  revision=QWEN_REVISION if self.model_name == QWEN_MODEL else None,
                                  local_files_only=True)
            self.get()
        except Exception:
            # The recording request reports actionable errors; startup stays healthy.
            self.phase = "idle"

    def get(self, disconnected=lambda: False):
        if self.session is not None:
            return self.session
        try:
            self.phase = "loading"
            from mlx_qwen3_asr import Session
            model_path = os.path.expanduser(self.model_name)
            if not Path(model_path).is_dir():
                from huggingface_hub import snapshot_download
                revision = QWEN_REVISION if self.model_name == QWEN_MODEL else None
                try:
                    model_path = snapshot_download(self.model_name, revision=revision, local_files_only=True)
                except Exception:
                    self.phase = "downloading"
                    # Download in a cancellable child, without owning a Metal context.
                    with tempfile.TemporaryFile(mode="w+t") as output:
                        process = subprocess.Popen([
                            sys.executable, "-B", "-c",
                            "import sys; from huggingface_hub import snapshot_download; print(snapshot_download(sys.argv[1], revision=sys.argv[2] or None))",
                            self.model_name, revision or "",
                        ], stdout=output, stderr=output)
                        try:
                            while process.poll() is None:
                                if disconnected():
                                    raise ConnectionAbortedError("Model download canceled")
                                time.sleep(0.1)
                            output.seek(0)
                            result = output.read().strip()
                            if process.returncode:
                                raise RuntimeError("Model download failed: " + result[-1000:])
                            model_path = result.splitlines()[-1]
                        finally:
                            if process.poll() is None:
                                process.terminate()
                                try:
                                    process.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    process.kill()
                                    process.wait()
            if disconnected():
                raise ConnectionAbortedError("Transcription canceled")
            self.phase = "loading"
            self.session = Session(model=model_path)
            return self.session
        finally:
            self.phase = "idle"

    @staticmethod
    def language(value):
        if not value or value.lower() in ("auto", "automatic", "detect"):
            return None
        return {"zh": "Chinese", "en": "English", "yue": "Cantonese", "ja": "Japanese"}.get(value, value)

    @staticmethod
    def decode_pcm(audio):
        import numpy as np
        return np.frombuffer(audio, dtype="<i2").astype(np.float32) / 32768.0

    def start(self, language, prompt, disconnected):
        now = time.monotonic()
        self.streams = {key: item for key, item in self.streams.items()
                        if now - item["touched"] < 30 and now - item["created"] < 310}
        if self.streams:
            raise ClientRequestError(409, "another recording is already active")
        session = self.get(disconnected)
        if disconnected():
            raise ConnectionAbortedError("Recording canceled")
        state = session.init_streaming(
            chunk_size_sec=1.0, max_context_sec=QWEN_CONTEXT_SECONDS, max_new_tokens=512,
            language=self.language(language), context=prompt or "",
        )
        identifier = uuid.uuid4().hex
        self.streams[identifier] = dict(state=state, bytes=0, sequence=0,
                                        created=time.monotonic(), touched=time.monotonic())
        return {"id": identifier, "text": "", "is_final": False}

    def update(self, identifier, audio, sequence, finish=False):
        item = self.streams.get(identifier)
        if item is None:
            raise ClientRequestError(404, "recording session not found")
        if time.monotonic() - item["touched"] > 30 or time.monotonic() - item["created"] > 310:
            del self.streams[identifier]
            raise ClientRequestError(408, "recording session expired")
        if sequence != item["sequence"]:
            raise ClientRequestError(409, "out-of-order audio chunk")
        if len(audio) % 2:
            raise ClientRequestError(400, "audio must be little-endian PCM16 mono at 16000 Hz")
        if item["bytes"] + len(audio) > STREAM_MAX_BYTES:
            del self.streams[identifier]
            raise ClientRequestError(413, "recording exceeds five minutes")
        try:
            if audio:
                item["state"] = self.session.feed_audio(self.decode_pcm(audio), item["state"])
            item["bytes"] += len(audio)
            item["sequence"] += 1
            item["touched"] = time.monotonic()
            if finish:
                item["state"] = self.session.finish_streaming(item["state"])
            return {"id": identifier, "text": item["state"].text,
                    "is_final": finish, "audio_seconds": item["bytes"] / 32000}
        except Exception:
            self.streams.pop(identifier, None)
            raise
        finally:
            if finish:
                self.streams.pop(identifier, None)

    def cancel(self, identifier):
        self.streams.pop(identifier, None)
        return {"ok": True}

    def transcribe(self, path, language, prompt, disconnected):
        import numpy as np
        session = self.get(disconnected)
        with wave.open(str(path)) as audio:
            if audio.getframerate() != 16000 or audio.getnchannels() != 1 or audio.getsampwidth() != 2:
                raise ClientRequestError(400, "Qwen requires 16000 Hz mono PCM16 WAV")
            pcm = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
        if not len(pcm):
            return "", None, 0
        result = session.transcribe(pcm, language=self.language(language), context=prompt or "", max_new_tokens=2048)
        return result.text, getattr(result, "language", None), len(pcm) / 16000


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class ModelCache:
    def __init__(self, device: str, compute_type: str, cpu_threads: int) -> None:
        self.device = device
        self.compute_type = compute_type
        self.cpu_threads = cpu_threads
        self._lock = threading.Lock()
        self._model_name: Optional[str] = None
        self._model = None
        self.phase = "idle"

    def get(self, model_name: str, disconnected=lambda: False):
        normalized = normalize_model_name(model_name)
        with self._lock:
            if self._model is not None and self._model_name == normalized:
                return self._model
            try:
                from faster_whisper import WhisperModel  # type: ignore
            except Exception as exc:
                raise RuntimeError(
                    "faster-whisper is not installed. Run `speek asr-install` first."
                ) from exc

            kwargs = {
                "device": self.device,
                "compute_type": self.compute_type,
            }
            if self.cpu_threads > 0:
                kwargs["cpu_threads"] = self.cpu_threads
            try:
                model_path = normalized
                if not os.path.isdir(normalized):
                    from faster_whisper.utils import download_model
                    try:
                        model_path = download_model(normalized, local_files_only=True)
                    except Exception:
                        self.phase = "downloading"
                        with tempfile.TemporaryFile(mode="w+t") as output:
                            process = subprocess.Popen(
                                [sys.executable, "-B", "-c", "import sys; from faster_whisper.utils import download_model; print(download_model(sys.argv[1]))", normalized],
                                stdout=output, stderr=output,
                            )
                            try:
                                while process.poll() is None:
                                    if disconnected():
                                        process.terminate()
                                        process.wait(timeout=10)
                                        raise ConnectionAbortedError("Model download canceled")
                                    time.sleep(0.2)
                                output.seek(0)
                                result = output.read().strip()
                                if process.returncode:
                                    raise RuntimeError("Model download failed: " + result[-1000:])
                                model_path = result.splitlines()[-1]
                            finally:
                                if process.poll() is None:
                                    process.kill()
                                    process.wait()
                if disconnected():
                    raise ConnectionAbortedError("Transcription canceled")
                self.phase = "loading"
                self._model = WhisperModel(model_path, **kwargs)
                self._model_name = normalized
                return self._model
            finally:
                self.phase = "idle"


def transcribe_faster_whisper(
    args: argparse.Namespace,
    cache: ModelCache,
    upload_path: Path,
    model_name: str,
    language: Optional[str],
    prompt: Optional[str],
    disconnected=lambda: False,
):
    model = cache.get(model_name, disconnected)
    segments, info = model.transcribe(
        str(upload_path),
        language=language,
        initial_prompt=prompt,
        vad_filter=args.vad_filter,
        beam_size=args.beam_size,
        condition_on_previous_text=False,
    )
    text = "".join(segment.text for segment in segments).strip()
    return text, getattr(info, "language", None), getattr(info, "duration", None)


def transcribe_whisper_cpp(
    args: argparse.Namespace,
    upload_path: Path,
    model_name: str,
    language: Optional[str],
    prompt: Optional[str],
):
    whisper_bin = Path(os.path.expanduser(args.whisper_cpp_bin))
    if not whisper_bin.exists():
        raise RuntimeError(f"whisper.cpp binary not found: {whisper_bin}")
    model_path = Path(normalize_model_name(model_name))
    if not model_path.exists():
        raise RuntimeError(f"whisper.cpp model not found: {model_path}")

    cmd = build_whisper_cpp_command(
        args,
        upload_path,
        model_path,
        language,
        prompt,
    )

    completed = subprocess.run(
        cmd,
        check=False,
        capture_output=True,
        text=True,
        timeout=args.whisper_cpp_timeout,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise RuntimeError(f"whisper.cpp failed with code {completed.returncode}: {detail[-1000:]}")

    text = completed.stdout.strip()
    return text, language, None


def build_whisper_cpp_command(
    args: argparse.Namespace,
    upload_path: Path,
    model_path: Path,
    language: Optional[str],
    prompt: Optional[str],
):
    whisper_bin = Path(os.path.expanduser(args.whisper_cpp_bin))
    cmd = [
        str(whisper_bin),
        "-m",
        str(model_path),
        "-f",
        str(upload_path),
        "-nt",
        "-np",
        "-bs",
        str(args.beam_size),
        "-bo",
        str(args.best_of),
    ]
    if args.cpu_threads > 0:
        cmd.extend(["-t", str(args.cpu_threads)])
    # whisper.cpp defaults to English when -l is omitted. Explicitly request
    # auto-detection so an empty product language works for Chinese/English
    # code-switching and remains backend/API neutral.
    cmd.extend(["-l", language or "auto"])
    if prompt:
        cmd.extend(["--prompt", prompt])
    return cmd


def field_value(
    form: cgi.FieldStorage,
    name: str,
    default: str = "",
    *,
    max_length: int,
) -> str:
    item = form[name] if name in form else None
    if item is None or getattr(item, "filename", None):
        return default
    value = item.value
    if isinstance(value, bytes):
        result = value.decode("utf-8", errors="replace")
    else:
        result = str(value)
    if len(result) > max_length:
        raise ClientRequestError(400, f"multipart field is too long: {name}")
    return result


def save_upload(form: cgi.FieldStorage, upload_dir: Path, max_bytes: int) -> Path:
    if "file" not in form:
        raise ClientRequestError(400, "missing multipart field: file")
    item = form["file"]
    if isinstance(item, list) or getattr(item, "file", None) is None:
        raise ClientRequestError(400, "multipart field 'file' must contain one uploaded file")
    filename = Path(getattr(item, "filename", "") or "audio.wav").name
    suffix = Path(filename).suffix or ".wav"
    upload_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(prefix="speek-asr-", suffix=suffix, dir=upload_dir, delete=False) as tmp:
            upload_path = Path(tmp.name)
            total = 0
            while True:
                chunk = item.file.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > max_bytes:
                    raise ClientRequestError(413, "uploaded audio exceeds the configured request limit")
                tmp.write(chunk)
        return upload_path
    except Exception:
        if upload_path is not None:
            try:
                upload_path.unlink()
            except OSError:
                pass
        raise


def select_model(configured_model: str, requested_model: str) -> str:
    requested = requested_model.strip()
    if not requested:
        return configured_model
    if normalize_model_name(requested) != normalize_model_name(configured_model):
        raise ClientRequestError(400, "the local ASR service does not allow per-request model overrides")
    return configured_model


def parse_content_length(raw_value: Optional[str], max_bytes: int) -> int:
    if raw_value is None:
        raise ClientRequestError(411, "Content-Length is required")
    try:
        length = int(raw_value)
    except ValueError as exc:
        raise ClientRequestError(400, "Content-Length must be an integer") from exc
    if length <= 0:
        raise ClientRequestError(400, "request body is empty")
    if length > max_bytes:
        raise ClientRequestError(413, "request body exceeds the configured limit")
    return length


def request_content_length(handler: BaseHTTPRequestHandler, max_bytes: int) -> int:
    return parse_content_length(handler.headers.get("Content-Length"), max_bytes)


def make_handler(args: argparse.Namespace, cache: ModelCache):
    class Handler(BaseHTTPRequestHandler):
        server_version = "speek-local-asr/0.2"

        def log_message(self, fmt: str, *values) -> None:  # type: ignore[no-untyped-def]
            if not args.quiet:
                super().log_message(fmt, *values)

        def client_disconnected(self) -> bool:
            try:
                readable, _, _ = select.select([self.connection], [], [], 0)
                return bool(readable) and self.connection.recv(1, socket.MSG_PEEK) == b""
            except OSError:
                return True

        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path == "/health":
                json_response(
                    self,
                    200,
                    {
                        "ok": True,
                        "backend": args.backend,
                        "model": normalize_model_name(args.model),
                        "model_phase": cache.phase,
                        "streaming": args.backend == "qwen-mlx",
                        "model_ready": cache.session is not None if isinstance(cache, QwenEngine) else cache._model is not None,
                    },
                )
                return
            json_response(self, 404, {"error": "not_found"})

        def stream_request(self, path):
            if args.backend != "qwen-mlx":
                json_response(self, 404, {"error": "streaming_not_supported"})
                return
            created_id = None
            try:
                if self.headers.get("Origin") is not None:
                    raise ClientRequestError(403, "browser-origin streaming requests are not allowed")
                match = re.fullmatch(r"/v1/audio/streams/([a-f0-9]{32})/(append|finish|cancel)", path)
                if path != "/v1/audio/streams" and not match:
                    raise ClientRequestError(404, "not_found")
                limit = 32768 if path == "/v1/audio/streams" else STREAM_CHUNK_BYTES
                size = request_content_length(self, min(limit, args.max_request_bytes))
                self.connection.settimeout(15)
                body = self.rfile.read(size)
                if len(body) != size:
                    raise ClientRequestError(400, "incomplete request body")
                if path == "/v1/audio/streams":
                    if self.headers.get_content_type() != "application/json":
                        raise ClientRequestError(415, "expected application/json")
                    try:
                        options = json.loads(body)
                    except (ValueError, UnicodeDecodeError):
                        raise ClientRequestError(400, "invalid JSON")
                    if not isinstance(options, dict):
                        raise ClientRequestError(400, "expected a JSON object")
                    for name, maximum in [("model", MAX_MODEL_LENGTH), ("language", MAX_LANGUAGE_LENGTH), ("prompt", MAX_PROMPT_LENGTH)]:
                        if not isinstance(options.get(name, ""), str) or len(options.get(name, "")) > maximum:
                            raise ClientRequestError(400, f"invalid {name}")
                    select_model(args.model, options.get("model", ""))
                    if options.get("sample_rate", 16000) != 16000:
                        raise ClientRequestError(400, "streaming requires 16000 Hz audio")
                    result = cache.run(cache.start, options.get("language"), options.get("prompt"), self.client_disconnected)
                    created_id = result["id"]
                    # A cancel may arrive after loading but before the start response.
                    if self.client_disconnected():
                        cache.run(cache.cancel, result["id"])
                        return
                else:
                    identifier, action = match.groups()
                    if action == "cancel":
                        result = cache.run(cache.cancel, identifier)
                    else:
                        if self.headers.get_content_type() != "application/octet-stream":
                            raise ClientRequestError(415, "expected PCM16 application/octet-stream")
                        try:
                            sequence = int(self.headers.get("X-Speek-Sequence", ""))
                        except ValueError:
                            raise ClientRequestError(400, "missing or invalid chunk sequence")
                        # Finish uses one sentinel byte; all actual PCM is sent by append.
                        audio = b"" if action == "finish" else body
                        result = cache.run(cache.update, identifier, audio, sequence, action == "finish")
                json_response(self, 200, result)
            except (ConnectionAbortedError, BrokenPipeError, ConnectionResetError):
                if created_id is not None:
                    cache.run(cache.cancel, created_id)
            except ClientRequestError as exc:
                json_response(self, exc.status, {"error": str(exc)})
            except TimeoutError:
                json_response(self, 408, {"error": "request body timed out"})
            except Exception as exc:
                json_response(self, 500, {"error": str(exc)})

        def do_POST(self) -> None:
            path = urlparse(self.path).path
            if path == "/v1/audio/streams" or path.startswith("/v1/audio/streams/"):
                self.stream_request(path)
                return
            if path != "/v1/audio/transcriptions":
                json_response(self, 404, {"error": "not_found"})
                return

            start = time.time()
            upload_path: Optional[Path] = None
            try:
                content_type = self.headers.get("Content-Type", "")
                if not content_type.lower().startswith("multipart/form-data;"):
                    raise ClientRequestError(415, "Content-Type must be multipart/form-data")
                content_length = request_content_length(self, args.max_request_bytes)
                form = cgi.FieldStorage(
                    fp=self.rfile,
                    headers=self.headers,
                    environ={
                        "REQUEST_METHOD": "POST",
                        "CONTENT_TYPE": content_type,
                        "CONTENT_LENGTH": str(content_length),
                    },
                )
                requested_model = field_value(form, "model", "", max_length=MAX_MODEL_LENGTH)
                model_name = select_model(args.model, requested_model)
                language = field_value(form, "language", "", max_length=MAX_LANGUAGE_LENGTH).strip() or None
                prompt = field_value(form, "prompt", "", max_length=MAX_PROMPT_LENGTH).strip() or None
                upload_path = save_upload(form, Path(args.tmp_dir), args.max_request_bytes)
                if args.backend == "qwen-mlx":
                    text, detected_language, duration = cache.run(
                        cache.transcribe, upload_path, language, prompt, self.client_disconnected,
                    )
                elif args.backend == "whisper-cpp":
                    text, detected_language, duration = transcribe_whisper_cpp(
                        args,
                        upload_path,
                        model_name,
                        language,
                        prompt,
                    )
                else:
                    text, detected_language, duration = transcribe_faster_whisper(
                        args,
                        cache,
                        upload_path,
                        model_name,
                        language,
                        prompt,
                        self.client_disconnected,
                    )
                json_response(
                    self,
                    200,
                    {
                        "text": text,
                        "backend": args.backend,
                        "model": normalize_model_name(model_name),
                        "language": detected_language,
                        "duration": duration,
                        "elapsed": round(time.time() - start, 3),
                    },
                )
            except (ConnectionAbortedError, BrokenPipeError, ConnectionResetError):
                pass
            except ClientRequestError as exc:
                json_response(self, exc.status, {"error": str(exc)})
            except Exception as exc:
                json_response(self, 500, {"error": str(exc)})
            finally:
                if upload_path is not None and not args.keep_uploads:
                    try:
                        upload_path.unlink()
                    except OSError:
                        pass

    return Handler


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="OpenAI-compatible local ASR server for Speek Coding.")
    parser.add_argument("--host", default=os.environ.get("SPEEK_ASR_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SPEEK_ASR_PORT", "8000")))
    parser.add_argument(
        "--backend",
        choices=["qwen-mlx", "faster-whisper", "whisper-cpp"],
        default=os.environ.get("SPEEK_ASR_BACKEND", "qwen-mlx" if sys.platform == "darwin" and platform.machine() == "arm64" else "faster-whisper"),
    )
    parser.add_argument("--model", default=os.environ.get("SPEEK_ASR_MODEL"))
    parser.add_argument("--device", default=os.environ.get("SPEEK_ASR_DEVICE", "cpu"))
    parser.add_argument("--compute-type", default=os.environ.get("SPEEK_ASR_COMPUTE_TYPE", "int8"))
    parser.add_argument("--cpu-threads", type=int, default=int(os.environ.get("SPEEK_ASR_CPU_THREADS", "0")))
    parser.add_argument("--beam-size", type=int, default=int(os.environ.get("SPEEK_ASR_BEAM_SIZE", "3")))
    parser.add_argument("--best-of", type=int, default=int(os.environ.get("SPEEK_ASR_BEST_OF", "1")))
    parser.add_argument("--whisper-cpp-bin", default=os.environ.get("SPEEK_WHISPER_CPP_BIN", "whisper-cli"))
    parser.add_argument(
        "--whisper-cpp-timeout",
        type=float,
        default=float(os.environ.get("SPEEK_WHISPER_CPP_TIMEOUT", "120")),
    )
    parser.add_argument("--tmp-dir", default=os.environ.get("SPEEK_ASR_TMP_DIR", tempfile.gettempdir()))
    parser.add_argument(
        "--max-request-bytes",
        type=int,
        default=int(os.environ.get("SPEEK_ASR_MAX_REQUEST_BYTES", str(DEFAULT_MAX_REQUEST_BYTES))),
    )
    parser.add_argument("--keep-uploads", action="store_true")
    parser.add_argument("--vad-filter", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)
    args.model = args.model or (QWEN_MODEL if args.backend == "qwen-mlx" else "turbo")

    if not is_loopback_host(args.host):
        parser.error("the built-in ASR service only binds to localhost or a loopback IP address")
    if args.max_request_bytes <= 0:
        parser.error("--max-request-bytes must be greater than zero")

    if args.backend == "qwen-mlx" and (sys.platform != "darwin" or platform.machine() != "arm64"):
        parser.error("qwen-mlx requires an Apple Silicon Mac")
    cache = QwenEngine(args.model) if args.backend == "qwen-mlx" else ModelCache(args.device, args.compute_type, args.cpu_threads)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(args, cache))
    if isinstance(cache, QwenEngine):
        cache.worker.submit(cache.warm_cached)
    print(
        f"Speek local ASR listening on http://{args.host}:{args.port} "
        f"backend={args.backend} model={normalize_model_name(args.model)} "
        f"device={args.device} compute_type={args.compute_type}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if isinstance(cache, QwenEngine):
            cache.worker.shutdown(wait=True, cancel_futures=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
