"""Explicit speech strategies for the currently verified target languages."""
from dataclasses import dataclass
from voxbridge.languages import language_profile


@dataclass(frozen=True)
class SpeechPolicy:
    language: str
    phonemizer_language: str
    default_audio_ms_per_char: float

    def split(self, text: str) -> tuple[str, ...]:
        from .chunks import _split_chinese_chunks, _split_english_chunks
        return _split_chinese_chunks(text) if self.language == 'Chinese' else _split_english_chunks(text)


_POLICIES = {
    'zh': SpeechPolicy('Chinese', 'cmn', 180.0),
    'en': SpeechPolicy('English', 'en-us', 65.0),
}


def speech_policy(language: str) -> SpeechPolicy:
    return _POLICIES[language_profile(language).code]
