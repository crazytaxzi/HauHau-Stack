from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def content_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts: list[str] = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text") or item.get("content")
                if isinstance(text, str):
                    parts.append(text)
        return "".join(parts)
    return ""


def clean_for_speech(text: str, limit: int) -> str:
    text = re.sub(r"<think>[\s\S]*?</think>", " ", text, flags=re.I)
    text = re.sub(r"<analysis>[\s\S]*?</analysis>", " ", text, flags=re.I)
    text = re.sub(r"```[\s\S]*?```", " Code omitted. ", text)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"https?://\S+", " link omitted ", text)
    text = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", text)
    text = re.sub(r"[*_#>|~]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


class SpeechWorker:
    def __init__(self, tts_host: str, tts_port: int, speed: float, cache_dir: Path, max_chars: int):
        self.tts_host = tts_host
        self.tts_port = tts_port
        self.speed = speed
        self.cache_dir = cache_dir
        self.max_chars = max_chars
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.last_error = ""
        self.last_file = ""

    def queue(self, text: str) -> None:
        cleaned = clean_for_speech(text, self.max_chars)
        if not cleaned:
            return
        threading.Thread(target=self._speak, args=(cleaned,), daemon=True).start()

    def _speak(self, text: str) -> None:
        with self.lock:
            try:
                payload = json.dumps(
                    {
                        "input": text,
                        "response_format": "wav",
                        "speed": self.speed,
                    }
                ).encode("utf-8")
                conn = http.client.HTTPConnection(self.tts_host, self.tts_port, timeout=900)
                conn.request(
                    "POST",
                    "/v1/audio/speech",
                    body=payload,
                    headers={
                        "Content-Type": "application/json",
                        "Accept": "audio/wav",
                        "Content-Length": str(len(payload)),
                    },
                )
                response = conn.getresponse()
                audio = response.read()
                status = response.status
                content_type = response.getheader("Content-Type", "")
                conn.close()

                if status < 200 or status >= 300:
                    detail = audio[:500].decode("utf-8", errors="replace")
                    raise RuntimeError(f"TTS HTTP {status}: {detail}")
                if len(audio) < 44 or audio[:4] != b"RIFF":
                    raise RuntimeError(
                        f"TTS returned {len(audio)} bytes with content type {content_type!r}, not a WAV file"
                    )

                stamp = int(time.time() * 1000)
                wav_path = self.cache_dir / f"reply-{stamp}.wav"
                wav_path.write_bytes(audio)
                latest = self.cache_dir / "latest.wav"
                try:
                    latest.unlink(missing_ok=True)
                    latest.symlink_to(wav_path.name)
                except OSError:
                    latest.write_bytes(audio)

                self.last_file = str(wav_path)
                self.last_error = ""
                self._play(wav_path)
                self._trim_cache()
            except Exception as exc:  # noqa: BLE001
                self.last_error = str(exc)
                print(f"voice-proxy: speech failed: {exc}", flush=True)

    def _play(self, wav_path: Path) -> None:
        if os.name == "nt":
            try:
                import winsound

                winsound.PlaySound(str(wav_path), winsound.SND_FILENAME)
                return
            except (ImportError, RuntimeError, OSError) as exc:
                print(f"voice-proxy: native Windows playback failed: {exc}", flush=True)

        if shutil.which("mpv"):
            result = subprocess.run(
                ["mpv", "--no-video", "--really-quiet", str(wav_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                return

        if shutil.which("ffplay"):
            result = subprocess.run(
                ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", str(wav_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                return

        raise RuntimeError("No working WAV player was found. Windows normally uses Python winsound automatically.")

    def _trim_cache(self) -> None:
        files = sorted(self.cache_dir.glob("reply-*.wav"), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in files[10:]:
            try:
                old.unlink()
            except OSError:
                pass


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HauHauVoiceProxy/2.0"

    @property
    def app(self) -> "VoiceProxyServer":
        return self.server  # type: ignore[return-value]

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"voice-proxy: {self.address_string()} - {fmt % args}", flush=True)

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        return self.rfile.read(length) if length > 0 else b""

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/__voice/status":
            self._json(
                200,
                {
                    "status": "ok",
                    "backend": f"http://{self.app.backend_host}:{self.app.backend_port}",
                    "tts": f"http://{self.app.speech.tts_host}:{self.app.speech.tts_port}",
                    "last_audio": self.app.speech.last_file,
                    "last_error": self.app.speech.last_error,
                },
            )
            return
        self._proxy()

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/__voice/test":
            body = self._read_body()
            text = "HauHau voice bridge is working on Windows."
            if body:
                try:
                    parsed = json.loads(body)
                    if isinstance(parsed, dict) and isinstance(parsed.get("text"), str):
                        text = parsed["text"]
                except json.JSONDecodeError:
                    pass
            self.app.speech.queue(text)
            self._json(202, {"queued": True, "text": text})
            return
        self._proxy()

    def do_PUT(self) -> None:  # noqa: N802
        self._proxy()

    def do_PATCH(self) -> None:  # noqa: N802
        self._proxy()

    def do_DELETE(self) -> None:  # noqa: N802
        self._proxy()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._proxy()

    def _proxy(self) -> None:
        body = self._read_body()
        speak_this_request = self._should_speak(body)

        headers: dict[str, str] = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in HOP_BY_HOP or lower in {"host", "accept-encoding"}:
                continue
            headers[key] = value
        headers["Host"] = f"{self.app.backend_host}:{self.app.backend_port}"
        headers["Accept-Encoding"] = "identity"
        headers["Connection"] = "close"
        if body:
            headers["Content-Length"] = str(len(body))

        conn = http.client.HTTPConnection(self.app.backend_host, self.app.backend_port, timeout=900)
        try:
            conn.request(self.command, self.path, body=body or None, headers=headers)
            upstream = conn.getresponse()
        except Exception as exc:  # noqa: BLE001
            conn.close()
            self._json(502, {"error": f"LLM backend connection failed: {exc}"})
            return

        response_headers = {key.lower(): value for key, value in upstream.getheaders()}
        content_type = response_headers.get("content-type", "")

        self.send_response(upstream.status, upstream.reason)
        for key, value in upstream.getheaders():
            lower = key.lower()
            if lower in HOP_BY_HOP or lower in {"content-length", "content-encoding"}:
                continue
            self.send_header(key, value)
        self.send_header("Connection", "close")
        self.end_headers()

        collected: list[str] = []
        try:
            if "text/event-stream" in content_type:
                self._stream_sse(upstream, collected)
            else:
                data = upstream.read()
                if data:
                    self.wfile.write(data)
                    self.wfile.flush()
                if speak_this_request and "application/json" in content_type:
                    collected.append(self._extract_json_response(data))
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()
            self.close_connection = True

        if speak_this_request:
            final_text = "".join(collected).strip()
            if final_text:
                print(f"voice-proxy: queued {len(final_text)} characters for speech", flush=True)
                self.app.speech.queue(final_text)

    def _stream_sse(self, upstream: http.client.HTTPResponse, collected: list[str]) -> None:
        while True:
            line = upstream.readline()
            if not line:
                break
            self.wfile.write(line)
            self.wfile.flush()
            stripped = line.strip()
            if not stripped.startswith(b"data:"):
                continue
            data = stripped[5:].strip()
            if not data or data == b"[DONE]":
                continue
            try:
                event = json.loads(data)
            except json.JSONDecodeError:
                continue
            choices = event.get("choices") if isinstance(event, dict) else None
            if not isinstance(choices, list) or not choices:
                continue
            choice = choices[0]
            if not isinstance(choice, dict):
                continue
            delta = choice.get("delta")
            if isinstance(delta, dict):
                text = content_text(delta.get("content"))
                if text:
                    collected.append(text)
            elif isinstance(choice.get("message"), dict):
                text = content_text(choice["message"].get("content"))
                if text:
                    collected.append(text)

    def _extract_json_response(self, data: bytes) -> str:
        try:
            parsed = json.loads(data)
        except json.JSONDecodeError:
            return ""
        choices = parsed.get("choices") if isinstance(parsed, dict) else None
        if not isinstance(choices, list) or not choices:
            return ""
        first = choices[0]
        if not isinstance(first, dict):
            return ""
        message = first.get("message")
        if isinstance(message, dict):
            return content_text(message.get("content"))
        return content_text(first.get("text"))

    def _should_speak(self, body: bytes) -> bool:
        if self.command != "POST" or not self.path.startswith("/v1/chat/completions"):
            return False
        if not body:
            return False
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            return False
        if not isinstance(payload, dict) or payload.get("stream") is not True:
            return False
        messages = payload.get("messages")
        if not isinstance(messages, list) or not messages:
            return False
        return any(isinstance(message, dict) and message.get("role") == "user" for message in messages)


class VoiceProxyServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        listen_host: str,
        listen_port: int,
        backend_host: str,
        backend_port: int,
        speech: SpeechWorker,
    ):
        self.backend_host = backend_host
        self.backend_port = backend_port
        self.speech = speech
        super().__init__((listen_host, listen_port), ProxyHandler)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Reverse proxy for llama.cpp with automatic Qwen TTS playback")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=8080)
    parser.add_argument("--backend-host", default="127.0.0.1")
    parser.add_argument("--backend-port", type=int, default=8082)
    parser.add_argument("--tts-host", default="127.0.0.1")
    parser.add_argument("--tts-port", type=int, default=9080)
    parser.add_argument("--speed", type=float, default=0.94)
    parser.add_argument("--max-chars", type=int, default=4000)
    parser.add_argument(
        "--cache-dir",
        default=str(Path(os.environ.get("LOCALAPPDATA", Path.home())) / "HauHauVoiceStack" / "audio"),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    speech = SpeechWorker(
        args.tts_host,
        args.tts_port,
        args.speed,
        Path(args.cache_dir),
        args.max_chars,
    )
    server = VoiceProxyServer(
        args.listen_host,
        args.listen_port,
        args.backend_host,
        args.backend_port,
        speech,
    )
    print(
        f"voice-proxy: http://{args.listen_host}:{args.listen_port} -> "
        f"http://{args.backend_host}:{args.backend_port}; TTS {args.tts_host}:{args.tts_port}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
