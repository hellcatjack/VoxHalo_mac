"""Enabled language configuration shared with the native App resource."""
from dataclasses import dataclass
from importlib.resources import files
import json


@dataclass(frozen=True)
class LanguageProfile:
    code: str
    name: str
    asr_label: str
    tts_label: str
    script: str = 'latin'


_CATALOG = json.loads(files('voxbridge').joinpath('language_catalog.json').read_text())
LANGUAGES = tuple(LanguageProfile(**{key: row[key] for key in
                  ('code', 'name', 'asr_label', 'tts_label', 'script')})
                  for row in _CATALOG['languages'])
_ALIASES = {alias.lower(): profile for row, profile in zip(_CATALOG['languages'], LANGUAGES)
            for alias in (profile.code, profile.name, profile.asr_label, *row['aliases'])}
CHINESE, ENGLISH = LANGUAGES[:2]


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
    parts = str(value).strip().lower().split('2')
    if len(parts) != 2 or any(part not in {p.code for p in LANGUAGES} for part in parts):
        raise ValueError(f'unsupported direction: {value}')
    return translation_pair(*parts)


def normalize_direction(value: object) -> str:
    """Accept canonical pairs and known legacy spellings; reject unknown explicit input."""
    raw = str(value or '').strip().lower()
    if not raw:
        return 'zh2en'
    for separator in ('->', '→'):
        if separator in raw:
            parts = raw.split(separator)
            if len(parts) == 2:
                return translation_pair(*parts).direction
    return pair_for_direction(raw).direction


def language_capabilities() -> dict:
    return {'version': 1, 'languages': [dict(code=p.code, name=p.name,
            asr_label=p.asr_label, tts_label=p.tts_label, script=p.script) for p in LANGUAGES],
            'directions': [translation_pair(a.code,b.code).direction for a in LANGUAGES
                           for b in LANGUAGES if a != b]}
