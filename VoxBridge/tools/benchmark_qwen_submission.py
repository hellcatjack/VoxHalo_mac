"""AMD-only in-process Qwen comparison: no test web port or public broadcast.

Run with the project's existing Python environment. Configuration is inherited
from the existing service but only an explicit non-secret allowlist is recorded.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
from pathlib import Path
import resource
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse
import wave

SAFE_SETTINGS = (
    "asr_model_path", "backend", "gpu_memory_utilization", "max_model_len",
    "max_new_tokens", "max_num_batched_tokens", "mm_processor_cache_gb",
    "unfixed_chunk_num", "unfixed_token_num", "chunk_size_sec",
    "segment_hard_cut_sec", "segment_overlap_sec", "segment_final_redecode",
    "final_redecode_on_stop", "vad_silence_sec", "early_translation_stable_sec",
    "early_translation_stable_hits", "stable_clause_target_cjk_chars",
    "qwen_submission_mode", "qwen_submission_budget_sec", "qwen_submission_target_cjk_chars",
    "translation_backend", "translation_api_model", "translation_max_new_tokens",
)


def distribution(values):
    if not values:
        return {}
    import numpy as np
    return {name: float(np.percentile(values, pct)) for name, pct in
            (("p50", 50), ("p95", 95), ("p99", 99), ("max", 100))}


def summarize(rows, calls):
    from voxbridge.streaming.submission_policy import PendingTextClock
    if any(row["event"].get("type") == "error" for row in rows):
        raise ValueError("Benchmark contains an error event")
    finals = [row["event"] for row in rows if row["event"].get("type") == "final"]
    if not finals or not (finals[-1].get("committed_text") or finals[-1].get("text", "")).strip():
        raise ValueError("Benchmark has no nonempty final transcript")
    partials, waits, gaps, commits, translations = [], [], [], [], []
    pending_clock, pending_ages = PendingTextClock(), []
    pending_segment = None
    for row in rows:
        event = row["event"]
        kind = event.get("type")
        if kind == "partial":
            partials.append(row)
            segment = event.get("stability", {}).get("segment_id")
            if segment != pending_segment:
                # Exported partials do not prove carry alignment. Reset this
                # diagnostic across windows instead of aging unrelated repeats.
                pending_clock.update("", row["wall_sec"])
                pending_segment = segment
            pending_clock.update(event.get("tentative_text", event.get("text", "")), row["wall_sec"])
        elif kind == "sentence_committed":
            segment = event.get("stability", {}).get("segment_id", event.get("segment_id"))
            needle = "".join(event["text"].split())
            if pending_clock.text and (pending_clock.text.startswith(needle) or needle.startswith(pending_clock.text)):
                pending_ages.append(pending_clock.age(row["wall_sec"]))
                if len(pending_clock.text) >= len(needle):
                    pending_clock.consume_prefix(needle)
                else:
                    pending_clock.update("", row["wall_sec"])
            # Exact recognized complete-unit appearance, NOT source word timing.
            matches = [p["wall_sec"] for p in partials
                       if segment is not None and p["event"].get("stability", {}).get("segment_id") == segment
                       and needle in "".join(p["event"].get("state_text", p["event"].get("text", "")).split())]
            if matches:
                waits.append(row["wall_sec"] - min(matches))
            if commits:
                gaps.append(row["wall_sec"] - commits[-1]["wall_sec"])
            commits.append(row)
        elif kind == "sentence_translation":
            translations.append(event)
    decoded = [call for call in calls if (call.get("decode_advance") or 0) > 0]
    return {
        "actual_decodes": sum(call["decode_advance"] for call in decoded),
        "observed_decode_calls": len(decoded),
        "decode_batch_sec": distribution([call["seconds"] for call in decoded]),
        "recognized_unit_wait_sec": distribution(waits),
        "recognized_unit_wait_samples": len(waits),
        "oldest_recognized_pending_age_sec": distribution(pending_ages),
        "oldest_recognized_pending_age_samples": len(pending_ages),
        "source_to_commit_latency_sec": None,
        "caption_gap_sec": distribution(gaps),
        "commit_count": len(commits), "translations": translations,
        "final_text": finals[-1].get("committed_text") or finals[-1]["text"],
    }


def validate_local_config(config):
    url = urlparse(config.translation_api_base_url)
    if url.hostname not in {"127.0.0.1", "localhost", "::1", "192.168.1.31"} or url.port != 8001:
        raise ValueError("Translation must use the existing local AMD port 8001")
    model = Path(config.asr_model_path)
    if not model.is_absolute() or not model.is_dir():
        raise ValueError("ASR requires an existing absolute local model directory")


def runtime_config():
    pid = subprocess.check_output(["systemctl", "--user", "show", "voxbridge-8024.service",
                                   "-p", "MainPID", "--value"], text=True).strip()
    command = Path(f"/proc/{pid}/cmdline").read_bytes().decode().strip("\0").split("\0")
    for entry in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"):
        key, sep, value = entry.partition(b"=")
        name = key.decode(errors="replace")
        if sep and (name.startswith(("HSA_", "HIP_", "ROCM_", "VLLM_", "PYTORCH_", "TORCH_", "OMP_"))
                    or name in {"LD_LIBRARY_PATH", "CUDA_VISIBLE_DEVICES"}):
            os.environ[name] = value.decode()
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1",
                      VLLM_NO_USAGE_STATS="1", DO_NOT_TRACK="1")
    os.environ.setdefault("VLLM_WORKER_MULTIPROC_METHOD", "spawn")
    import voxbridge.cli.demo_streaming_ws as demo
    old_argv = sys.argv
    try:
        sys.argv = [command[0]] + command[command.index("voxbridge.cli.demo_streaming_ws") + 1:]
        config = demo.parse_args()
    finally:
        sys.argv = old_argv
    if not Path(config.asr_model_path).is_dir():
        from huggingface_hub import snapshot_download
        config.asr_model_path = snapshot_download(config.asr_model_path, local_files_only=True)
    validate_local_config(config)
    return config


class TimedASR:
    def __init__(self, model):
        self.model, self.calls = model, []

    def __getattr__(self, name):
        method = getattr(self.model, name)
        if name not in {"streaming_transcribe", "finish_streaming_transcribe", "transcribe"}:
            return method
        def timed(*args, **kwargs):
            state = args[-1] if args else None
            before = getattr(state, "chunk_id", None)
            begin = time.monotonic()
            result = method(*args, **kwargs)
            after = getattr(state, "chunk_id", None)
            advance = max(0, after - before) if type(before) is int and type(after) is int else None
            self.calls.append({"method": name, "seconds": time.monotonic() - begin, "decode_advance": advance})
            return result
        return timed


def run_case(config, model, raw, folder, mode, window, options):
    from fastapi.testclient import TestClient
    import voxbridge.cli.demo_streaming_ws as demo
    config.auth_enabled = False  # In-process test app only; no listening socket.
    config.enable_tts = False
    config.qwen_submission_mode = mode
    config.qwen_submission_budget_sec = options.budget
    config.qwen_submission_target_cjk_chars = options.target
    config.segment_hard_cut_sec = window
    config.subtitle_trace_log = True
    config.subtitle_trace_log_file = str(folder / "trace.jsonl")
    config.subtitle_trace_log_partial_every = 1
    config.tts_hls_root_dir = str(folder / "unused-hls")
    config.idle_timeout_sec = 300
    config.asr_context_schedule = ""
    config.force_language = "Chinese"
    translator = demo.OpenAIAPITranslator(
        base_url=config.translation_api_base_url, model=config.translation_api_model,
        source_language=config.translation_source_language, target_language=config.translation_target_language,
        max_new_tokens=config.translation_max_new_tokens, timeout_sec=config.translation_api_timeout_sec,
        api_key=config.translation_api_key,
    ) if options.translation else None
    asr = TimedASR(model)
    app = demo._create_app(config, asr, translator=translator)
    rows, failures = [], []
    done = threading.Event()
    started = time.monotonic()
    audio_sec = len(raw) / 32000
    with (folder / "events.jsonl").open("x", encoding="utf-8") as output:
        with TestClient(app) as client, client.websocket_connect("/ws") as ws:
            assert ws.receive_json()["type"] == "ready"
            ws.send_json({"type": "start", "translation_direction": "zh2en", "tts_enabled": False})
            while True:
                event = ws.receive_json()
                if event["type"] == "error":
                    raise RuntimeError("Test app failed to start")
                if event["type"] == "started":
                    break
            started = time.monotonic()
            def read():
                try:
                    while True:
                        event = ws.receive_json()
                        row = {"wall_sec": time.monotonic() - started, "event": event}
                        rows.append(row)
                        output.write(json.dumps(row, ensure_ascii=False) + "\n")
                        output.flush()
                        if event["type"] in {"error", "final"}:
                            break
                except Exception as exc:
                    failures.append(type(exc).__name__)
                finally:
                    done.set()
            reader = threading.Thread(target=read, daemon=True)
            reader.start()
            next_progress = 30
            for offset in range(0, len(raw), 3200):
                if done.is_set():
                    raise RuntimeError("Benchmark ended before all audio was sent")
                end = min(offset + 3200, len(raw))
                time.sleep(max(0, started + end / 32000 - time.monotonic()))
                ws.send_bytes(raw[offset:end])
                if end / 32000 >= next_progress:
                    print(json.dumps({"mode": mode, "window": window, "audio_sec": end / 32000,
                                      "wall_sec": round(time.monotonic() - started, 2)}), flush=True)
                    next_progress += 30
            ws.send_json({"type": "finish", "mode": "stop"})
            if not done.wait(180):
                raise TimeoutError("No final event after Stop")
            reader.join(5)
    if failures:
        raise RuntimeError(f"Benchmark receiver failed: {failures}")
    result = summarize(rows, asr.calls)
    result.update(audio_sec=audio_sec, source_offset_sec=options.offset,
                  wall_sec=time.monotonic() - started,
                  compute_sec=sum(call["seconds"] for call in asr.calls),
                  parent_max_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024,
                  settings={key: getattr(config, key, None) for key in SAFE_SETTINGS})
    for name, value in (("result.json", result), ("calls.json", asr.calls)):
        (folder / name).write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key not in {"final_text", "translations", "settings"}}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--wav", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--offset", type=float, default=0)
    parser.add_argument("--duration", type=float, default=180)
    parser.add_argument("--modes", nargs="+", choices=["off", "shadow", "adaptive"], default=["off", "adaptive"])
    parser.add_argument("--windows", nargs="+", type=float, default=[45])
    parser.add_argument("--budget", type=float, default=8)
    parser.add_argument("--target", type=int, default=24)
    parser.add_argument("--translation", action="store_true")
    options = parser.parse_args()
    logging.basicConfig(level=logging.WARNING)
    config = runtime_config()
    if options.inspect:
        print(json.dumps({key: getattr(config, key, None) for key in SAFE_SETTINGS}, indent=2))
        return
    if not options.wav or not options.output or options.duration <= 0 or options.offset < 0:
        parser.error("Provide local --wav, new --output, nonnegative offset and positive duration")
    options.output.mkdir(parents=True, exist_ok=False)
    with wave.open(str(options.wav), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
            raise ValueError("Expected original mono 16-bit 16 kHz PCM WAV")
        source.setpos(round(options.offset * 16000))
        raw = source.readframes(round(options.duration * 16000))
    from qwen_asr import Qwen3ASRModel
    import voxbridge.cli.demo_streaming_ws as demo
    print("Loading cached local Qwen model for isolated comparison", flush=True)
    model = Qwen3ASRModel.LLM(model=config.asr_model_path, **demo._vllm_model_kwargs(config))
    for window in options.windows:
        for mode in options.modes:
            folder = options.output / f"{mode}-{window:g}s"
            folder.mkdir()
            run_case(config, model, raw, folder, mode, window, options)


if __name__ == "__main__":
    main()
