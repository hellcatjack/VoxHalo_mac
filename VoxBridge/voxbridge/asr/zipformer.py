"""Native sherpa-onnx online transducer, finalized by VoxBridge's VAD."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from .engines import XL_FILES


@dataclass
class ZipformerState:
    stream: Any
    language: str = "Chinese"
    force_language: str = "Chinese"
    text: str = ""
    finished: bool = False
    received_samples: int = 0


class ZipformerASR:
    def __init__(self, model_dir: str, num_threads: int = 2, *, recognizer: Any = None):
        if num_threads < 1:
            raise ValueError("Zipformer num_threads must be positive")
        if recognizer is None:
            root = Path(model_dir)
            missing = [name for name in XL_FILES if not (root / name).is_file()]
            if missing:
                raise ValueError("Zipformer XL model files missing: " + ", ".join(missing))
            import sherpa_onnx
            recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
                tokens=str(root / "tokens.txt"), encoder=str(root / "encoder.int8.onnx"),
                decoder=str(root / "decoder.onnx"), joiner=str(root / "joiner.int8.onnx"),
                num_threads=num_threads, sample_rate=16000, provider="cpu",
                model_type="zipformer2", decoding_method="modified_beam_search",
                max_active_paths=4, enable_endpoint_detection=False,
            )
        self.recognizer = recognizer

    def init_streaming_state(self, *, language: str | None = None, **kwargs) -> ZipformerState:
        if language not in (None, "", "Chinese", "中文", "zh", "zh-CN"):
            raise ValueError("Zipformer XL supports Chinese only")
        return ZipformerState(stream=self.recognizer.create_stream())

    def _drain(self, state: ZipformerState) -> None:
        while self.recognizer.is_ready(state.stream):
            self.recognizer.decode_stream(state.stream)
        state.text = self.recognizer.get_result(state.stream).strip()

    def streaming_transcribe(self, wav: np.ndarray, state: ZipformerState) -> None:
        if state.finished:
            raise ValueError("Zipformer stream is already finished")
        samples = np.asarray(wav, dtype=np.float32)
        if samples.ndim != 1 or not np.all(np.isfinite(samples)):
            raise ValueError("Zipformer requires finite mono PCM samples")
        if not samples.size:
            return
        state.stream.accept_waveform(16000, samples)
        state.received_samples += samples.size
        self._drain(state)

    def finish_streaming_transcribe(self, state: ZipformerState) -> None:
        if state.finished:
            return
        # Mark before native operations: a failed finish cannot re-feed its tail.
        state.finished = True
        if not state.received_samples:
            return
        state.stream.accept_waveform(16000, np.zeros(12800, dtype=np.float32))
        state.stream.input_finished()
        self._drain(state)
