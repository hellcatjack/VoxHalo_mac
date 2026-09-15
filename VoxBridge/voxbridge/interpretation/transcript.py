"""A source-text policy boundary, separate from ASR revision ownership."""
from dataclasses import dataclass
from typing import Protocol
from voxbridge.streaming.sentence_rules import _split_translation_units_and_tail
from voxbridge.languages import language_profile
import re


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


_ABBREVIATIONS = {
    'fr': {'m', 'mme', 'mlle', 'dr', 'pr', 'st', 'ste', 'etc', 'p', 'ex'},
    'es': {'sr', 'sra', 'srta', 'dr', 'dra', 'ud', 'uds', 'p', 'ej', 'etc'},
    'it': {'sig', 'sig.ra', 'sig.na', 'dott', 'dott.ssa', 'prof', 'ecc'},
    'pt': {'sr', 'sra', 'srta', 'dr', 'dra', 'prof', 'etc', 'p', 'ex'},
}


@dataclass(frozen=True)
class MultilingualTextPolicy:
    language_code: str

    def split(self, text: str) -> tuple[list[str], str]:
        """Commit complete sentences; retain the unpunctuated tail for stabilization."""
        text = str(text or '').strip()
        units, start, cursor = [], 0, 0
        closers = '\"\'”’）)]】》」』'
        while cursor < len(text):
            char = text[cursor]
            boundary = char in '。！？!?।॥'
            if char == '.':
                token = re.search(r'([\w.]+)$', text[:cursor], re.UNICODE)
                word = token.group(1).lower() if token else ''
                decimal = cursor > 0 and cursor + 1 < len(text) and text[cursor-1].isdigit() and text[cursor+1].isdigit()
                abbreviation = word in _ABBREVIATIONS.get(self.language_code, set())
                initial = bool(token and len(token.group(1)) == 1 and token.group(1).isalpha())
                boundary = not (decimal or abbreviation or initial)
            if boundary:
                end = cursor + 1
                while end < len(text) and (text[end] in closers or text[end] in '。！？!?।॥.'):
                    end += 1
                unit = text[start:end].strip()
                if unit:
                    units.append(unit)
                start = end
                cursor = end
            else:
                cursor += 1
        return units, text[start:].strip()


def source_text_policy(language: str, *, target_cjk_chars: int = 32,
                       target_latin_words: int = 24) -> SourceTextPolicy:
    profile = language_profile(language)
    if profile.code in {'zh', 'en'}:
        return ChineseEnglishTextPolicy(target_cjk_chars, target_latin_words)
    return MultilingualTextPolicy(profile.code)
