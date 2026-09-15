"""Explicit speech strategies for the currently verified target languages."""
from dataclasses import dataclass
from voxbridge.languages import language_profile


@dataclass(frozen=True)
class SpeechPolicy:
    language: str
    phonemizer_language: str
    default_audio_ms_per_char: float

    def split(self, text: str) -> tuple[str, ...]:
        from .chunks import _split_chinese_chunks, _split_english_chunks, _split_multilingual_chunks
        if self.language == 'Chinese':
            return _split_chinese_chunks(text)
        if self.language == 'English':
            return _split_english_chunks(text)
        return _split_multilingual_chunks(text)


_POLICIES = {
    'zh': SpeechPolicy('Chinese', 'cmn', 180.0),
    'en': SpeechPolicy('English', 'en-us', 65.0),
    # Provisional scheduling estimates: Japanese mora-like characters, Latin
    # letters, and Devanagari code points. Playback duration remains authoritative.
    'ja': SpeechPolicy('Japanese', 'ja', 150.0),
    'fr': SpeechPolicy('French', 'fr-fr', 70.0),
    'es': SpeechPolicy('Spanish', 'es', 65.0),
    'it': SpeechPolicy('Italian', 'it', 65.0),
    'pt': SpeechPolicy('Portuguese', 'pt-br', 70.0),
    'hi': SpeechPolicy('Hindi', 'hi', 90.0),
}


def speech_policy(language: str) -> SpeechPolicy:
    return _POLICIES[language_profile(language).code]
