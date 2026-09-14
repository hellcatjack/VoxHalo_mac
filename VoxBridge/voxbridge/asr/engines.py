"""Production Qwen-only registry; never imports or loads optional ASR models."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Any, Callable

from voxbridge.languages import LANGUAGES

ZIPFORMER_DISABLED = "Zipformer XL is disabled; refresh the page and use Qwen3-ASR"
# Public data used by the retained standalone adapter, not a production loader.
XL_FILES = ("encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt")


@dataclass(frozen=True)
class EngineBinding:
    id: str
    asr: Any
    streaming: bool
    supports_context: bool
    supports_final_redecode: bool
    supports_overlap: bool
    tokenizer: Any = None
    infer_lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class ASREngineRegistry:
    def __init__(self, qwen_asr: Any, *, qwen_backend: str = "vllm",
                 zipformer_model_dir: str = "", zipformer_num_threads: int = 2,
                 zipformer_factory: Callable[[], Any] | None = None):
        # Accept legacy configuration without inspecting files, retaining a factory
        # or creating optional inference state. It cannot enable the disabled engine.
        self._qwen = EngineBinding(
            "qwen3-asr", qwen_asr, qwen_backend in {"vllm", "mlx"}, True, True, True,
            getattr(getattr(qwen_asr, "processor", None), "tokenizer", None),
        )

    def describe(self) -> list[dict]:
        return [
            {"id": "qwen3-asr", "name": "Qwen3-ASR", "languages": [language.asr_label for language in LANGUAGES],
             "available": True, "load_state": "ready", "supports_context": True},
        ]

    def get(self, engine_id: str = "qwen3-asr", language: str | None = None) -> EngineBinding:
        if engine_id == "zipformer-xl":
            raise ValueError(ZIPFORMER_DISABLED)
        if engine_id != "qwen3-asr":
            raise ValueError(f"Unknown ASR engine: {engine_id}")
        return self._qwen
