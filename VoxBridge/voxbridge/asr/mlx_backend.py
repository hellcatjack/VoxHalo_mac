"""MLX Qwen3-ASR adapter for VoxBridge's existing streaming protocol.

The MLX runtime performs repeated full-window decodes.  It intentionally does
not use mlx-qwen3-asr's incremental cache because that path did not meet the
quality baseline for this deployment.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
import threading
from types import SimpleNamespace
from typing import Any, Callable, Optional

import numpy as np


SAMPLE_RATE = 16000


@dataclass
class MLXStreamingState:
    context: str = ""
    language: str = ""
    force_language: Optional[str] = None
    text: str = ""
    audio_accum: np.ndarray = field(
        default_factory=lambda: np.zeros((0,), dtype=np.float32)
    )
    buffer: np.ndarray = field(
        default_factory=lambda: np.zeros((0,), dtype=np.float32)
    )
    unfixed: str = ""
    unfixed_chunk_num: int = 2
    unfixed_token_num: int = 5
    chunk_size_sec: float = 2.0
    decode_interval_samples: int = 2 * SAMPLE_RATE
    last_decoded_samples: int = 0
    chunk_id: int = 0
    _raw_decoded: str = ""


@dataclass(frozen=True)
class MLXTranscriptionResult:
    text: str
    language: str
    segments: Any = None
    chunks: Any = None
    finish_reason: Optional[str] = None
    truncated: bool = False


def _default_runtime_factory(model_path: str, precision: str) -> Any:
    """Load the verified MLX runtime without importing it on non-MLX paths."""
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_qwen3_asr import Session

    session = Session(model_path, dtype=mx.float16)
    if precision == "int8":
        nn.quantize(session.model, bits=8, group_size=64)
        mx.eval(session.model.parameters())
        mx.clear_cache()

    # Materialize the runtime on its owner thread before serving real audio.
    session.transcribe(
        np.zeros((SAMPLE_RATE,), dtype=np.float32),
        max_new_tokens=32,
    )
    return session


class MLXQwenASR:
    """Qwen-compatible bounded-window ASR with one MLX-owning executor."""

    def __init__(
        self,
        model_path: str,
        precision: str = "int8",
        max_new_tokens: int = 256,
        *,
        max_audio_sec: float = 45.0,
        gpu_lock: Optional[threading.Lock] = None,
        runtime_factory: Optional[Callable[[str, str], Any]] = None,
    ) -> None:
        if precision not in {"fp16", "int8"}:
            raise ValueError("Qwen precision must be fp16 or int8")
        if int(max_new_tokens) <= 0:
            raise ValueError("max_new_tokens must be positive")
        if not np.isfinite(max_audio_sec) or float(max_audio_sec) <= 0:
            raise ValueError("max_audio_sec must be positive")

        local_model = Path(str(model_path)).expanduser()
        if not local_model.is_dir() or not (local_model / "config.json").is_file():
            raise ValueError(
                "MLX Qwen ASR requires a local model directory containing config.json"
            )

        self.model_path = str(local_model.resolve())
        self.precision = precision
        self.max_new_tokens = int(max_new_tokens)
        self.max_audio_samples = max(1, int(round(float(max_audio_sec) * SAMPLE_RATE)))
        self.gpu_lock = gpu_lock or threading.Lock()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="qwen-metal")
        self._closed = False
        factory = runtime_factory or _default_runtime_factory
        self._runtime = self._executor.submit(self._load_owned, factory).result()
        self.processor = SimpleNamespace(
            tokenizer=getattr(self._runtime, "tokenizer", None)
        )

    def _load_owned(self, factory: Callable[[str, str], Any]) -> Any:
        with self.gpu_lock:
            return factory(self.model_path, self.precision)

    def _validate_context(self, context: Any) -> str:
        if not isinstance(context, str):
            raise ValueError("context must be text")
        if len(context) > 512:
            raise ValueError("context must not exceed 512 characters")
        return context

    @staticmethod
    def _validate_language(language: Any) -> Optional[str]:
        if language is None:
            return None
        if not isinstance(language, str):
            raise ValueError("language must be text or None")
        value = language.strip()
        return value or None

    @staticmethod
    def _validate_audio_array(audio: Any) -> np.ndarray:
        try:
            samples = np.asarray(audio, dtype=np.float32)
        except (TypeError, ValueError) as exc:
            raise ValueError("audio must be a one-dimensional numeric array") from exc
        if samples.ndim != 1:
            raise ValueError("audio must be a one-dimensional numeric array")
        if not np.isfinite(samples).all():
            raise ValueError("audio samples must be finite")
        return np.ascontiguousarray(samples)

    def _ensure_open(self) -> None:
        if self._closed:
            raise RuntimeError("MLX ASR backend is closed")

    def init_streaming_state(
        self,
        context: str = "",
        language: Optional[str] = None,
        chunk_size_sec: float = 2.0,
        **kwargs: Any,
    ) -> MLXStreamingState:
        self._ensure_open()
        context_value = self._validate_context(context)
        language_value = self._validate_language(language)
        if not np.isfinite(chunk_size_sec) or float(chunk_size_sec) <= 0:
            raise ValueError("chunk_size_sec must be positive")
        interval = max(1, int(round(float(chunk_size_sec) * SAMPLE_RATE)))
        return MLXStreamingState(
            context=context_value,
            force_language=language_value,
            unfixed_chunk_num=int(kwargs.get("unfixed_chunk_num", 2)),
            unfixed_token_num=int(kwargs.get("unfixed_token_num", 5)),
            chunk_size_sec=float(chunk_size_sec),
            decode_interval_samples=interval,
        )

    def _transcribe_owned(
        self,
        audio: np.ndarray,
        context: str,
        language: Optional[str],
    ) -> MLXTranscriptionResult:
        with self.gpu_lock:
            output = self._runtime.transcribe(
                audio,
                context=context,
                language=language,
                max_new_tokens=self.max_new_tokens,
            )
        if bool(getattr(output, "truncated", False)):
            raise RuntimeError(
                "Qwen transcription was truncated; shorten the audio window and retry"
            )
        return MLXTranscriptionResult(
            text=str(getattr(output, "text", "") or "").strip(),
            language=str(getattr(output, "language", "") or ""),
            segments=getattr(output, "segments", None),
            chunks=getattr(output, "chunks", None),
            finish_reason=getattr(output, "finish_reason", None),
            truncated=False,
        )

    def _decode(self, state: MLXStreamingState) -> MLXStreamingState:
        audio = np.asarray(state.audio_accum, dtype=np.float32).reshape(-1).copy()
        result = self._executor.submit(
            self._transcribe_owned,
            audio,
            state.context,
            state.force_language,
        ).result()
        state.language = result.language
        state.text = result.text
        state._raw_decoded = result.text
        state.unfixed = result.text
        state.last_decoded_samples = int(audio.size)
        state.buffer = np.zeros((0,), dtype=np.float32)
        state.chunk_id += 1
        return state

    def streaming_transcribe(
        self,
        wav: Any,
        state: MLXStreamingState,
    ) -> MLXStreamingState:
        self._ensure_open()
        samples = self._validate_audio_array(wav)
        if samples.size == 0:
            return state

        old_audio = self._validate_audio_array(state.audio_accum)
        new_size = int(old_audio.size + samples.size)
        if new_size > self.max_audio_samples:
            raise ValueError(
                "audio exceeds the configured maximum bounded window"
            )

        state.audio_accum = np.concatenate((old_audio, samples))
        state.buffer = np.concatenate(
            (self._validate_audio_array(state.buffer), samples)
        )
        if (
            new_size - int(state.last_decoded_samples)
            < int(state.decode_interval_samples)
        ):
            return state
        return self._decode(state)

    def finish_streaming_transcribe(
        self,
        state: MLXStreamingState,
    ) -> MLXStreamingState:
        self._ensure_open()
        audio = self._validate_audio_array(state.audio_accum)
        if audio.size > self.max_audio_samples:
            raise ValueError("audio exceeds the configured maximum bounded window")
        if int(audio.size) > int(state.last_decoded_samples):
            return self._decode(state)
        return state

    @staticmethod
    def _normalize_audio_inputs(audio: Any) -> list[tuple[Any, int]]:
        if (
            isinstance(audio, tuple)
            and len(audio) == 2
            and isinstance(audio[1], (int, np.integer))
        ):
            return [(audio[0], int(audio[1]))]
        if isinstance(audio, list):
            normalized = []
            for item in audio:
                if not isinstance(item, tuple) or len(item) != 2:
                    raise ValueError("audio entries must be (samples, sample_rate) tuples")
                normalized.append((item[0], int(item[1])))
            return normalized
        return [(audio, SAMPLE_RATE)]

    def transcribe(
        self,
        audio: Any,
        context: str = "",
        language: Optional[str] = None,
    ) -> list[MLXTranscriptionResult]:
        self._ensure_open()
        context_value = self._validate_context(context)
        language_value = self._validate_language(language)
        results = []
        for raw_samples, sample_rate in self._normalize_audio_inputs(audio):
            if int(sample_rate) != SAMPLE_RATE:
                raise ValueError("MLX Qwen ASR requires 16000 Hz audio")
            samples = self._validate_audio_array(raw_samples)
            if samples.size > self.max_audio_samples:
                raise ValueError("audio exceeds the configured maximum bounded window")
            results.append(
                self._executor.submit(
                    self._transcribe_owned,
                    samples.copy(),
                    context_value,
                    language_value,
                ).result()
            )
        return results

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._executor.shutdown(wait=True)
