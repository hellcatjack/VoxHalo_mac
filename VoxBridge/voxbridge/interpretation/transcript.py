"""A source-text policy boundary, separate from ASR revision ownership."""
from dataclasses import dataclass
from typing import Protocol
from voxbridge.streaming.sentence_rules import _split_translation_units_and_tail


class SourceTextPolicy(Protocol):
    def split(self, text: str) -> tuple[list[str], str]: ...


@dataclass(frozen=True)
class ChineseEnglishTextPolicy:
    """Current mixed Chinese/English rules; new scripts require another policy."""
    target_cjk_chars: int = 32
    target_latin_words: int = 24

    def split(self, text: str) -> tuple[list[str], str]:
        return _split_translation_units_and_tail(
            text, target_cjk_chars=self.target_cjk_chars,
            target_latin_words=self.target_latin_words,
        )
