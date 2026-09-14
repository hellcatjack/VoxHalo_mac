"""Exercise the real XL WebSocket path in-process, without publishing audio."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from queue import Queue, Empty
import resource
import sys
from threading import Thread
import time
from types import SimpleNamespace
import wave

from fastapi.testclient import TestClient

from voxbridge.asr import ASREngineRegistry
from voxbridge.asr.zipformer import ZipformerASR
from voxbridge.cli.demo_streaming_ws import _create_app, parse_args


def read_pcm_window(path: Path, start_sec: float, duration_sec: float) -> bytes:
    if start_sec < 0 or duration_sec <= 0:
        raise ValueError("start must be nonnegative and duration positive")
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
            raise ValueError("expected mono 16 kHz PCM16 WAV")
        first = round(start_sec * 16000)
        if first >= source.getnframes():
            raise ValueError("audio window starts beyond EOF")
        source.setpos(first)
        raw = source.readframes(round(duration_sec * 16000))
    if not raw:
        raise ValueError("empty audio window")
    return raw


def pcm_frames(pcm: bytes, *, chunk_samples: int = 3200):
    if chunk_samples < 1 or len(pcm) % 2:
        raise ValueError("expected complete PCM16 samples and a positive chunk size")
    for offset in range(0, len(pcm), chunk_samples * 2):
        end = min(len(pcm), offset + chunk_samples * 2)
        yield pcm[offset:end], end / 32000.0


def summarize_events(events, *, audio_started: float, input_seconds: float,
                     decode_seconds: float, audio_finished: float | None = None) -> dict:
    finals = [(stamp, row) for stamp, row in events if row.get("type") == "final"]
    if not finals:
        raise RuntimeError("probe did not receive a final result")
    first_partial = next((stamp - audio_started for stamp, row in events
                          if row.get("type") == "partial" and row.get("text")), None)
    commits = [(stamp, row) for stamp, row in events if row.get("type") == "sentence_committed"]
    final_at, final = finals[-1]
    tail_start = audio_finished if audio_finished is not None else audio_started + input_seconds
    return {
        "input_seconds": input_seconds, "first_partial_sec": first_partial,
        "first_commit_sec": commits[0][0] - audio_started if commits else None,
        "wall_seconds": final_at - audio_started,
        "tail_finalize_sec": max(0.0, final_at - tail_start),
        "decode_seconds": decode_seconds, "decode_rtf": decode_seconds / input_seconds,
        "commits": len(commits), "final_text": final.get("text", ""),
        "committed_text": final.get("committed_text", ""),
    }


class MeasuredZipformer(ZipformerASR):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.decode_seconds = 0.0
        self.decode_calls = 0

    def _measure(self, method, *args):
        started = time.monotonic()
        try:
            return method(*args)
        finally:
            self.decode_seconds += time.monotonic() - started
            self.decode_calls += 1

    def streaming_transcribe(self, wav, state):
        return self._measure(super().streaming_transcribe, wav, state)

    def finish_streaming_transcribe(self, state):
        return self._measure(super().finish_streaming_transcribe, state)


class UnusedQwen:
    def init_streaming_state(self, **kwargs):
        # The existing ready handshake creates an empty default state only.
        return SimpleNamespace(text="", language="", force_language=kwargs.get("language"))

    def __getattr__(self, name):
        if name == "processor":
            return None
        raise AssertionError(f"XL probe unexpectedly called Qwen: {name}")


def run_probe(app, pcm: bytes, *, realtime: bool, timeout_sec: float = 120.0):
    events, pending = [], Queue()
    with TestClient(app).websocket_connect("/ws") as ws:
        def collect():
            try:
                while True:
                    row = ws.receive_json()
                    stamped = (time.monotonic(), row)
                    events.append(stamped)
                    pending.put(stamped)
                    if row.get("type") in ("error", "final"):
                        return
            except Exception as exc:
                pending.put((time.monotonic(), {"type": "error", "message": str(exc)}))

        reader = Thread(target=collect, daemon=True)
        reader.start()

        def receive(kind):
            deadline = time.monotonic() + timeout_sec
            while True:
                try:
                    _, row = pending.get(timeout=max(0.001, deadline - time.monotonic()))
                except Empty as exc:
                    raise TimeoutError(f"waiting for {kind}") from exc
                if row.get("type") == "error":
                    raise RuntimeError(row.get("message", "probe failed"))
                if row.get("type") == kind:
                    return row

        receive("ready")
        ws.send_json({"type": "start", "asr_engine": "zipformer-xl",
                      "translation_direction": "zh2en", "language": "Chinese"})
        started = receive("started")
        if started.get("asr_engine") != "zipformer-xl":
            raise RuntimeError("server did not select XL")
        audio_started = time.monotonic()
        for frame, due in pcm_frames(pcm):
            if realtime:
                time.sleep(max(0.0, audio_started + due - time.monotonic()))
            ws.send_bytes(frame)
        audio_finished = time.monotonic()
        ws.send_json({"type": "finish", "mode": "stop"})
        receive("final")
        reader.join(timeout=1)
    return events, audio_started, audio_finished


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--start-sec", type=float, default=0)
    parser.add_argument("--duration-sec", type=float, default=30)
    parser.add_argument("--realtime", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    pcm = read_pcm_window(options.audio, options.start_sec, options.duration_sec)
    old_argv = sys.argv
    try:
        sys.argv = ["dual-asr-probe", "--chunk-size-sec", "0.6", "--force-language", "Chinese",
                    "--segment-hard-cut-sec", "45", "--vad-min-slice-sec", "3.5",
                    "--vad-silence-sec", "0.7"]
        args = parse_args()
    finally:
        sys.argv = old_argv
    registry = ASREngineRegistry(UnusedQwen(), zipformer_factory=lambda: MeasuredZipformer(options.model_dir))
    args.subtitle_trace_log = True
    options.output.parent.mkdir(parents=True, exist_ok=True)
    args.subtitle_trace_log_file = str(options.output.with_suffix(".trace.jsonl"))
    app = _create_app(args, registry.get().asr, asr_registry=registry)
    events, audio_started, audio_finished = run_probe(app, pcm, realtime=options.realtime)
    measured = registry.get("zipformer-xl", "Chinese").asr
    result = summarize_events(events, audio_started=audio_started, audio_finished=audio_finished,
                              input_seconds=len(pcm) / 32000.0, decode_seconds=measured.decode_seconds)
    result.update({"realtime": options.realtime, "start_sec": options.start_sec,
                   "audio": str(options.audio), "model_dir": options.model_dir,
                   "load_seconds": registry.describe()[1]["load_seconds"],
                   "decode_calls": measured.decode_calls,
                   "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
                   "events": [{"elapsed_sec": round(stamp - audio_started, 6), **row} for stamp, row in events]})
    options.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "events"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
