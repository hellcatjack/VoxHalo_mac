from __future__ import annotations

import builtins
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import sys
import threading
import time
from types import ModuleType, SimpleNamespace

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voxbridge.asr.engines import ASREngineRegistry
from voxbridge.asr.mlx_backend import MLXQwenASR


@dataclass
class _RuntimeResult:
    text: str
    language: str
    truncated: bool = False


class _RecordingRuntime:
    def __init__(self, calls, *, delay: float = 0.0):
        self.calls = calls
        self.delay = delay
        self.tokenizer = SimpleNamespace(encode=lambda text, **_: list(text))
        self._active = 0
        self.max_active = 0

    def transcribe(self, audio, **kwargs):
        self._active += 1
        self.max_active = max(self.max_active, self._active)
        try:
            if self.delay:
                time.sleep(self.delay)
            samples = np.asarray(audio, dtype=np.float32).copy()
            self.calls.append(
                {
                    "thread": threading.get_ident(),
                    "audio": samples,
                    **kwargs,
                }
            )
            return _RuntimeResult(
                text=f"samples:{samples.size}",
                language=kwargs.get("language") or "Chinese",
            )
        finally:
            self._active -= 1


@pytest.fixture
def backend_factory(tmp_path):
    backends = []
    model_path = tmp_path / "qwen3-asr-0.6b"
    model_path.mkdir()
    (model_path / "config.json").write_text("{}", encoding="utf-8")

    def make(**kwargs):
        calls = []
        runtime_threads = []
        delay = kwargs.pop("delay", 0.0)

        def runtime_factory(model_path, precision):
            runtime_threads.append(threading.get_ident())
            calls.append({"load": (model_path, precision), "thread": threading.get_ident()})
            return _RecordingRuntime(calls, delay=delay)

        backend = MLXQwenASR(
            str(model_path),
            runtime_factory=runtime_factory,
            **kwargs,
        )
        backends.append(backend)
        return backend, calls, runtime_threads

    yield make

    for backend in backends:
        backend.close()


def _decode_calls(calls):
    return [call for call in calls if "audio" in call]


def test_streaming_states_do_not_share_mutable_audio_or_text(backend_factory):
    backend, _, _ = backend_factory()

    first = backend.init_streaming_state(context="PCCS", language="Chinese")
    second = backend.init_streaming_state(context="ESV", language="English")
    backend.streaming_transcribe(np.ones(8, dtype=np.float32), first)

    assert first.audio_accum.tolist() == [1.0] * 8
    assert second.audio_accum.size == 0
    assert second.buffer.size == 0
    assert second.text == ""
    assert second.unfixed == ""
    assert first.context == "PCCS"
    assert second.context == "ESV"


def test_streaming_accumulates_every_sample_and_decodes_only_at_interval(backend_factory):
    backend, calls, _ = backend_factory()
    state = backend.init_streaming_state(chunk_size_sec=0.002)

    backend.streaming_transcribe(np.arange(16, dtype=np.float32), state)
    assert _decode_calls(calls) == []
    assert state.buffer.tolist() == list(np.arange(16, dtype=np.float32))

    backend.streaming_transcribe(np.arange(16, 32, dtype=np.float32), state)
    decode_calls = _decode_calls(calls)
    assert len(decode_calls) == 1
    np.testing.assert_array_equal(decode_calls[0]["audio"], np.arange(32, dtype=np.float32))
    assert state.audio_accum.tolist() == list(np.arange(32, dtype=np.float32))
    assert state.buffer.size == 0
    assert state.last_decoded_samples == 32
    assert state.chunk_id == 1
    assert state.text == "samples:32"


def test_finish_decodes_undecoded_tail_once_and_state_can_continue(backend_factory):
    backend, calls, _ = backend_factory()
    state = backend.init_streaming_state(chunk_size_sec=1.0)

    backend.streaming_transcribe(np.ones(16, dtype=np.float32), state)
    backend.finish_streaming_transcribe(state)
    backend.finish_streaming_transcribe(state)
    backend.streaming_transcribe(np.full(8, 2.0, dtype=np.float32), state)
    backend.finish_streaming_transcribe(state)

    decode_calls = _decode_calls(calls)
    assert [call["audio"].size for call in decode_calls] == [16, 24]
    assert state.chunk_id == 2
    assert state.last_decoded_samples == 24
    assert state.text == "samples:24"


def test_streaming_and_batch_forward_context_language_and_token_limit(backend_factory):
    backend, calls, _ = backend_factory(max_new_tokens=256)
    state = backend.init_streaming_state(
        context="PCCS Nehemiah",
        language="English",
        chunk_size_sec=0.001,
        unfixed_chunk_num=4,
        unfixed_token_num=7,
    )

    backend.streaming_transcribe(np.ones(16, dtype=np.float32), state)
    results = backend.transcribe(
        audio=[(np.ones(5, dtype=np.float32), 16000)],
        context="ESV",
        language="English",
    )

    streaming_call, batch_call = _decode_calls(calls)
    assert streaming_call["context"] == "PCCS Nehemiah"
    assert streaming_call["language"] == "English"
    assert streaming_call["max_new_tokens"] == 256
    assert state.unfixed_chunk_num == 4
    assert state.unfixed_token_num == 7
    assert batch_call["context"] == "ESV"
    assert batch_call["language"] == "English"
    assert results[0].text == "samples:5"
    assert results[0].language == "English"


def test_streaming_rejects_invalid_or_oversized_audio_without_mutating_state(backend_factory):
    backend, calls, _ = backend_factory(max_audio_sec=0.001)
    state = backend.init_streaming_state(chunk_size_sec=1.0)
    backend.streaming_transcribe(np.ones(8, dtype=np.float32), state)

    with pytest.raises(ValueError, match="45 seconds|configured maximum|maximum"):
        backend.streaming_transcribe(np.ones(9, dtype=np.float32), state)
    with pytest.raises(ValueError, match="finite"):
        backend.streaming_transcribe(np.array([np.nan], dtype=np.float32), state)
    with pytest.raises(ValueError, match="16000"):
        backend.transcribe((np.ones(8, dtype=np.float32), 8000))

    assert state.audio_accum.tolist() == [1.0] * 8
    assert _decode_calls(calls) == []


def test_all_runtime_work_uses_one_owner_thread_and_serializes_calls(backend_factory):
    caller_thread = threading.get_ident()
    backend, calls, runtime_threads = backend_factory(delay=0.02)

    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [
            pool.submit(
                backend.transcribe,
                (np.full(16, index, dtype=np.float32), 16000),
            )
            for index in range(4)
        ]
        for future in futures:
            assert future.result(timeout=2)[0].text == "samples:16"

    decode_calls = _decode_calls(calls)
    runtime = backend._runtime
    assert runtime_threads[0] != caller_thread
    assert {call["thread"] for call in decode_calls} == {runtime_threads[0]}
    assert runtime.max_active == 1
    assert isinstance(backend.gpu_lock, type(threading.Lock()))


def test_default_loader_uses_fp16_activations_affine_int8_group64(monkeypatch, tmp_path):
    events = []

    class FakeModel:
        def parameters(self):
            events.append(("parameters", threading.get_ident()))
            return {"weight": object()}

    class FakeSession:
        def __init__(self, model_path, *, dtype):
            events.append(("session", model_path, dtype, threading.get_ident()))
            self.model = FakeModel()
            self.tokenizer = object()

        def transcribe(self, audio, **kwargs):
            events.append(("transcribe", np.asarray(audio).size, kwargs, threading.get_ident()))
            return _RuntimeResult("warm", "Chinese")

    mlx_package = ModuleType("mlx")
    mlx_core = ModuleType("mlx.core")
    mlx_core.float16 = object()
    mlx_core.eval = lambda params: events.append(("eval", params, threading.get_ident()))
    mlx_core.clear_cache = lambda: events.append(("clear_cache", threading.get_ident()))
    mlx_nn = ModuleType("mlx.nn")
    mlx_nn.quantize = lambda model, **kwargs: events.append(
        ("quantize", model, kwargs, threading.get_ident())
    )
    mlx_package.core = mlx_core
    mlx_package.nn = mlx_nn
    runtime_module = ModuleType("mlx_qwen3_asr")
    runtime_module.Session = FakeSession
    monkeypatch.setitem(sys.modules, "mlx", mlx_package)
    monkeypatch.setitem(sys.modules, "mlx.core", mlx_core)
    monkeypatch.setitem(sys.modules, "mlx.nn", mlx_nn)
    monkeypatch.setitem(sys.modules, "mlx_qwen3_asr", runtime_module)

    model_path = tmp_path / "qwen"
    model_path.mkdir()
    (model_path / "config.json").write_text("{}", encoding="utf-8")
    backend = MLXQwenASR(str(model_path), precision="int8")
    try:
        session_event = next(event for event in events if event[0] == "session")
        quantize_event = next(event for event in events if event[0] == "quantize")
        warmup_event = next(event for event in events if event[0] == "transcribe")
        assert session_event[1:3] == (str(model_path), mlx_core.float16)
        assert quantize_event[2] == {"bits": 8, "group_size": 64}
        assert warmup_event[1] == 16000
        assert warmup_event[2]["max_new_tokens"] == 32
        owner_thread = session_event[-1]
        assert all(event[-1] == owner_thread for event in events)
    finally:
        backend.close()


def test_registry_marks_mlx_as_streaming_and_exposes_tokenizer(backend_factory):
    backend, _, _ = backend_factory()
    registry = ASREngineRegistry(backend, qwen_backend="mlx")

    binding = registry.get()
    assert binding.streaming is True
    assert binding.tokenizer is backend.processor.tokenizer


def test_mlx_backend_validation_rejects_unsupported_precision(backend_factory):
    with pytest.raises(ValueError, match="fp16 or int8"):
        backend_factory(precision="int4")


def test_mlx_backend_rejects_remote_or_incomplete_model_paths():
    factory_called = False

    def runtime_factory(model_path, precision):
        nonlocal factory_called
        factory_called = True
        return _RecordingRuntime([])

    with pytest.raises(ValueError, match="local model directory"):
        MLXQwenASR(
            "Qwen/Qwen3-ASR-0.6B",
            runtime_factory=runtime_factory,
        )
    assert factory_called is False


def test_cli_mlx_loader_does_not_import_torch_or_qwen_asr(monkeypatch):
    from voxbridge.cli import demo_streaming_ws

    fake_backend = object()
    fake_module = ModuleType("voxbridge.asr.mlx_backend")
    fake_module.MLXQwenASR = lambda *args, **kwargs: fake_backend
    monkeypatch.setitem(sys.modules, "voxbridge.asr.mlx_backend", fake_module)

    real_import = builtins.__import__

    def guarded_import(name, *args, **kwargs):
        if name == "torch" or name.startswith("qwen_asr"):
            raise AssertionError(f"MLX startup imported {name}")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", guarded_import)
    args = SimpleNamespace(
        backend="mlx",
        asr_model_path="/local/qwen",
        mlx_precision="int8",
        max_new_tokens=256,
    )

    assert demo_streaming_ws._load_asr_backend(args) is fake_backend


def test_cli_accepts_mlx_backend_and_precision(monkeypatch):
    from voxbridge.cli.demo_streaming_ws import parse_args

    monkeypatch.setattr(
        sys,
        "argv",
        ["demo", "--backend", "mlx", "--mlx-precision", "fp16"],
    )
    args = parse_args()
    assert args.backend == "mlx"
    assert args.mlx_precision == "fp16"


def test_cli_shares_mlx_gpu_admission_lock_with_translator():
    from voxbridge.cli.demo_streaming_ws import _share_gpu_admission_lock

    shared = threading.Lock()
    asr = SimpleNamespace(gpu_lock=shared)
    translator = SimpleNamespace(_lock=threading.Lock())

    _share_gpu_admission_lock("mlx", asr, translator)

    assert translator._lock is shared


def test_mlx_bounded_window_is_not_given_gapped_pcm_by_decode_skip_gate():
    from voxbridge.cli.demo_streaming_ws import _should_skip_stream_decode

    quiet_tail = dict(
        in_speech=True,
        silence_ms=100.0,
        segment_elapsed_ms=4000.0,
        snr_db=0.0,
        vad_silence_ms=800.0,
        vad_exit_snr_db=4.0,
        has_pending_text=True,
    )

    assert _should_skip_stream_decode(backend="mlx", **quiet_tail) is False
    assert _should_skip_stream_decode(backend="vllm", **quiet_tail) is True


def test_mlx_window_retains_low_energy_pcm_after_speech_starts(backend_factory):
    from voxbridge.cli.demo_streaming_ws import _should_skip_stream_decode

    backend, calls, _ = backend_factory()
    state = backend.init_streaming_state(chunk_size_sec=0.002)
    frames = (
        (np.full(16, 0.5, dtype=np.float32), 18.0, 0.0),
        (np.full(16, 0.001, dtype=np.float32), 0.0, 100.0),
    )
    for frame, snr_db, silence_ms in frames:
        skip = _should_skip_stream_decode(
            backend="mlx",
            in_speech=True,
            silence_ms=silence_ms,
            segment_elapsed_ms=2000.0,
            snr_db=snr_db,
            vad_silence_ms=800.0,
            vad_exit_snr_db=4.0,
            has_pending_text=True,
        )
        if not skip:
            backend.streaming_transcribe(frame, state)

    decoded = _decode_calls(calls)[0]["audio"]
    np.testing.assert_array_equal(
        decoded,
        np.concatenate([frame for frame, _, _ in frames]),
    )


def test_received_pre_speech_pcm_stays_in_mlx_window_and_stop_flushes_once(backend_factory):
    from voxbridge.cli.demo_streaming_ws import _should_skip_stream_decode

    backend, calls, _ = backend_factory(max_audio_sec=0.001)
    state = backend.init_streaming_state(chunk_size_sec=0.001)
    silence = np.zeros(16, dtype=np.float32)

    skip = _should_skip_stream_decode(
        backend="mlx",
        in_speech=False,
        silence_ms=0.0,
        segment_elapsed_ms=200.0,
        snr_db=-20.0,
        vad_silence_ms=800.0,
        vad_exit_snr_db=4.0,
        has_pending_text=False,
    )
    if not skip:
        backend.streaming_transcribe(silence, state)
    backend.finish_streaming_transcribe(state)

    assert skip is False
    assert state.audio_accum.tolist() == [0.0] * 16
    assert len(_decode_calls(calls)) == 1


def test_mlx_long_silence_with_context_never_publishes_context_echo(tmp_path):
    from voxbridge.cli.demo_streaming_ws import _create_app

    model_path = tmp_path / "qwen"
    model_path.mkdir()
    (model_path / "config.json").write_text("{}", encoding="utf-8")

    class ContextEchoRuntime:
        tokenizer = SimpleNamespace(encode=lambda text, **_: list(text))

        def transcribe(self, audio, **kwargs):
            return _RuntimeResult(
                text=kwargs.get("context", ""),
                language=kwargs.get("language") or "Chinese",
            )

    backend = MLXQwenASR(
        str(model_path),
        runtime_factory=lambda *_: ContextEchoRuntime(),
    )
    args = SimpleNamespace(
        backend="mlx",
        force_language=None,
        translation_source_language="Chinese",
        translation_target_language="English",
        max_new_tokens=256,
        audio_queue_size=32,
        client_chunk_ms=100,
        consumer_batch_sec=0.5,
        max_connections=1,
        max_frame_samples=32000,
        unfixed_chunk_num=2,
        unfixed_token_num=5,
        chunk_size_sec=2.0,
        min_audio_sec=1.0,
        decode_interval_sec=2.0,
        idle_timeout_sec=30,
        asr_context_apply_mode="streaming",
        tts_revision_stable_sec=0.0,
        tts_latest_revision_grace_sec=0.0,
    )
    app = _create_app(args, backend)
    events = []
    try:
        with TestClient(app).websocket_connect("/ws") as ws:
            assert ws.receive_json()["type"] == "ready"
            ws.send_json(
                {
                    "type": "start",
                    "translation_direction": "zh2en",
                    "asr_context_terms": ["PCCS", "尼希米", "受浸典礼"],
                }
            )
            while True:
                event = ws.receive_json()
                if event.get("type") == "started":
                    break
            for _ in range(5):
                ws.send_bytes(np.zeros(32000, dtype="<i2").tobytes())
            ws.send_json({"type": "finish"})
            while True:
                event = ws.receive_json()
                events.append(event)
                if event.get("type") == "final":
                    break
    finally:
        backend.close()

    assert not [event for event in events if event.get("type") == "sentence_committed"]
    assert all(not str(event.get("text", "")).strip() for event in events)


def test_mlx_long_silence_without_context_never_publishes_model_hallucination(
    tmp_path,
):
    from voxbridge.cli.demo_streaming_ws import _create_app

    model_path = tmp_path / "qwen"
    model_path.mkdir()
    (model_path / "config.json").write_text("{}", encoding="utf-8")

    class SilenceHallucinationRuntime:
        tokenizer = SimpleNamespace(encode=lambda text, **_: list(text))

        def transcribe(self, audio, **kwargs):
            return _RuntimeResult(text="嗯。", language="Chinese")

    backend = MLXQwenASR(
        str(model_path),
        runtime_factory=lambda *_: SilenceHallucinationRuntime(),
    )
    args = SimpleNamespace(
        backend="mlx",
        force_language=None,
        translation_source_language="Chinese",
        translation_target_language="English",
        max_new_tokens=256,
        audio_queue_size=32,
        client_chunk_ms=100,
        consumer_batch_sec=0.5,
        max_connections=1,
        max_frame_samples=32000,
        unfixed_chunk_num=2,
        unfixed_token_num=5,
        chunk_size_sec=2.0,
        min_audio_sec=1.0,
        decode_interval_sec=2.0,
        idle_timeout_sec=30,
        asr_context_apply_mode="streaming",
        tts_revision_stable_sec=0.0,
        tts_latest_revision_grace_sec=0.0,
    )
    app = _create_app(args, backend)
    events = []
    try:
        with TestClient(app).websocket_connect("/ws") as ws:
            assert ws.receive_json()["type"] == "ready"
            for _ in range(5):
                ws.send_bytes(np.zeros(32000, dtype="<i2").tobytes())
            ws.send_json({"type": "finish"})
            while True:
                event = ws.receive_json()
                events.append(event)
                if event.get("type") == "final":
                    break
    finally:
        backend.close()

    assert not [event for event in events if event.get("type") == "sentence_committed"]
    assert all(not str(event.get("text", "")).strip() for event in events)


def test_mlx_stop_keeps_short_tail_when_silero_observed_quiet_speech(
    monkeypatch,
    tmp_path,
):
    from voxbridge.cli import demo_streaming_ws
    from voxbridge.streaming.vad_support import SileroShadowObserver

    monkeypatch.setattr(
        demo_streaming_ws,
        "create_silero_onnx_observer",
        lambda threshold: SileroShadowObserver(
            runner=lambda frame: 0.99 if np.max(np.abs(frame)) > 0 else 0.0,
            frame_samples=512,
            threshold=threshold,
        ),
    )

    model_path = tmp_path / "qwen"
    model_path.mkdir()
    (model_path / "config.json").write_text("{}", encoding="utf-8")

    class ShortSpeechRuntime:
        tokenizer = SimpleNamespace(encode=lambda text, **_: list(text))

        def transcribe(self, audio, **kwargs):
            samples = np.asarray(audio, dtype=np.float32)
            text = (
                "请大家一起祷告。"
                if np.max(np.abs(samples), initial=0.0) > 0
                else "嗯。"
            )
            return _RuntimeResult(text=text, language="Chinese")

    backend = MLXQwenASR(
        str(model_path),
        runtime_factory=lambda *_: ShortSpeechRuntime(),
    )
    args = SimpleNamespace(
        backend="mlx",
        force_language=None,
        translation_source_language="Chinese",
        translation_target_language="English",
        max_new_tokens=256,
        audio_queue_size=32,
        client_chunk_ms=100,
        consumer_batch_sec=0.5,
        max_connections=1,
        max_frame_samples=32000,
        unfixed_chunk_num=2,
        unfixed_token_num=5,
        chunk_size_sec=2.0,
        min_audio_sec=1.0,
        decode_interval_sec=2.0,
        idle_timeout_sec=30,
        asr_context_apply_mode="streaming",
        silero_vad_rescue=True,
        silero_vad_shadow_threshold=0.5,
        segment_hard_cut_sec=1.0,
        segment_overlap_sec=0.0,
        tts_revision_stable_sec=0.0,
        tts_latest_revision_grace_sec=0.0,
    )
    app = demo_streaming_ws._create_app(args, backend)
    events = []
    try:
        with TestClient(app).websocket_connect("/ws") as ws:
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(np.full(8000, 131, dtype="<i2").tobytes())
            ws.send_bytes(np.zeros(8000, dtype="<i2").tobytes())
            ws.send_bytes(np.zeros(32000, dtype="<i2").tobytes())
            ws.send_json({"type": "finish"})
            while True:
                event = ws.receive_json()
                events.append(event)
                if event.get("type") == "final":
                    break
    finally:
        backend.close()

    commits = [
        event["text"]
        for event in events
        if event.get("type") == "sentence_committed"
    ]
    assert commits == ["请大家一起祷告。"]
    assert next(event for event in events if event.get("type") == "final")["text"] == ""
