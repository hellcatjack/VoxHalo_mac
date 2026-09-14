"""Qwen-only production ASR; importing this package does not load a model."""

from .engines import ASREngineRegistry, EngineBinding

__all__ = ["ASREngineRegistry", "EngineBinding"]
