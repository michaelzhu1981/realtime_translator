#!/usr/bin/env python3
"""Minimal persistent MLX Whisper ASR service for the macOS app."""

from __future__ import annotations

import argparse
import json
import os
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


class TranscriptionJob:
    def __init__(self, audio_path: str, language: str | None) -> None:
        self.audio_path = audio_path
        self.language = language
        self.done = threading.Event()
        self.response: dict[str, Any] | None = None
        self.error: BaseException | None = None


class ASRRuntime:
    def __init__(self, model: str, language: str, owner_token: str, request_timeout: float) -> None:
        self.model_name = model
        self.default_language = language
        self.owner_token = owner_token
        self.request_timeout = request_timeout
        self.started_at = time.time()
        self._mlx_whisper: Any | None = None
        self._jobs: queue.Queue[TranscriptionJob] = queue.Queue()
        self._worker = threading.Thread(target=self._process_jobs, daemon=True)
        self._worker.start()

    def load(self) -> None:
        import mlx_whisper

        self._mlx_whisper = mlx_whisper

    def transcribe(self, audio_path: str, language: str | None) -> dict[str, Any]:
        job = TranscriptionJob(audio_path=audio_path, language=language)
        self._jobs.put(job)
        if not job.done.wait(timeout=self.request_timeout):
            raise TimeoutError(f"ASR transcription timed out after {self.request_timeout:g}s")

        if job.error is not None:
            raise job.error
        if job.response is None:
            raise RuntimeError("transcription job finished without a response")
        return job.response

    def _process_jobs(self) -> None:
        while True:
            job = self._jobs.get()
            try:
                job.response = self._transcribe_now(job.audio_path, job.language)
            except BaseException as exc:  # noqa: BLE001 - errors are returned by the HTTP boundary.
                job.error = exc
            finally:
                job.done.set()
                self._jobs.task_done()

    def _transcribe_now(self, audio_path: str, language: str | None) -> dict[str, Any]:
        if self._mlx_whisper is None:
            self.load()

        path = Path(audio_path).expanduser()
        if not path.exists():
            raise FileNotFoundError(f"audio file not found: {path}")

        start = time.perf_counter()
        kwargs: dict[str, Any] = {"path_or_hf_repo": self.model_name}
        selected_language = language or self.default_language
        if selected_language and selected_language != "auto":
            kwargs["language"] = selected_language

        result = self._mlx_whisper.transcribe(str(path), **kwargs)
        duration_ms = int((time.perf_counter() - start) * 1000)

        return {
            "text": (result.get("text") or "").strip(),
            "language": result.get("language") or selected_language,
            "duration_ms": duration_ms,
            "segments": result.get("segments") or [],
        }


class Handler(BaseHTTPRequestHandler):
    runtime: ASRRuntime

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json({
                "ok": True,
                "model": self.runtime.model_name,
                "owner_token": self.runtime.owner_token,
                "pid": os.getpid(),
                "started_at": self.runtime.started_at,
            })
            return
        self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/transcribe":
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            response = self.runtime.transcribe(
                audio_path=payload["audio_path"],
                language=payload.get("language"),
            )
            response["request_id"] = payload.get("request_id")
            self._send_json(response)
        except TimeoutError as exc:
            self._send_json({"error": str(exc)}, status=504)
        except Exception as exc:  # noqa: BLE001 - service boundary returns JSON errors.
            self._send_json({"error": str(exc)}, status=500)

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--language", default="auto")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--owner-token", required=True)
    parser.add_argument("--request-timeout", type=float, default=30)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    Handler.runtime = ASRRuntime(
        model=args.model,
        language=args.language,
        owner_token=args.owner_token,
        request_timeout=args.request_timeout,
    )
    Handler.runtime.load()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
