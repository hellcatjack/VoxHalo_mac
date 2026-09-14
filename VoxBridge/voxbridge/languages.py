"""Validated language configuration; only verified directions are enabled."""
from dataclasses import dataclass


@dataclass(frozen=True)
class LanguageProfile:
    code: str
    name: str
    asr_label: str
    tts_label: str


CHINESE = LanguageProfile('zh', '中文', 'Chinese', 'Chinese')
ENGLISH = LanguageProfile('en', '英文', 'English', 'English')
LANGUAGES = (CHINESE, ENGLISH)
_ALIASES = {'zh': CHINESE, 'chinese': CHINESE, '中文': CHINESE,
            'zh-cn': CHINESE, 'zh-hans': CHINESE, 'zh-hant': CHINESE,
            'en': ENGLISH, 'english': ENGLISH, '英文': ENGLISH, '英语': ENGLISH,
            'en-us': ENGLISH, 'en-gb': ENGLISH}


def language_profile(value: str) -> LanguageProfile:
    try:
        return _ALIASES[value.strip().lower()]
    except (KeyError, AttributeError) as exc:
        raise ValueError(f'unsupported language: {value}') from exc


@dataclass(frozen=True)
class TranslationPair:
    source: LanguageProfile
    target: LanguageProfile

    @property
    def direction(self) -> str:
        return f'{self.source.code}2{self.target.code}'


def translation_pair(source: str, target: str) -> TranslationPair:
    pair = TranslationPair(language_profile(source), language_profile(target))
    if pair.source == pair.target:
        raise ValueError('source and target languages must differ')
    return pair


def legacy_direction(value: object) -> str:
    """Keep the historic wire default at the compatibility boundary only."""
    normalized = str(value or '').strip().lower()
    return 'en2zh' if normalized in {'en2zh', 'en->zh', 'english->chinese', '英文->中文'} else 'zh2en'


def pair_for_direction(value: str) -> TranslationPair:
    if value == 'zh2en':
        return translation_pair('zh', 'en')
    if value == 'en2zh':
        return translation_pair('en', 'zh')
    raise ValueError(f'unsupported direction: {value}')
