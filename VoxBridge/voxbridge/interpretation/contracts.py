"""Session-owned work; models and transport are not part of these records."""
import asyncio
from dataclasses import dataclass, field
from typing import Any, NamedTuple


class TranslationRequest(NamedTuple):
    sentence_id: str
    revision: int
    source_text: str
    language: str
    seq: int
    generation: int
    source_language: str
    target_language: str
    direction: str


@dataclass
class TranslationRuntime:
    direction: str = 'zh2en'
    source_language: str = 'Chinese'
    target_language: str = 'English'
    parallelism: int = 1
    task: asyncio.Task | None = None
    queue: asyncio.Queue[TranslationRequest] = field(default_factory=lambda: asyncio.Queue(maxsize=256))
    latest_by_sentence: dict[str, Any] = field(default_factory=dict)
