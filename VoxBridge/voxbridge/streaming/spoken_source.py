"""Recover added source text without replaying an already released utterance."""
from __future__ import annotations

import regex
from collections.abc import Sequence


_CJK_SCRIPTS = r"[\p{Han}\p{scx=Hiragana}\p{scx=Katakana}]"
_WORD_CHAR = r"[[\p{L}\p{M}\p{N}]--[\p{Han}\p{scx=Hiragana}\p{scx=Katakana}]]"
_TOKEN_PATTERN = regex.compile(
    rf"(?=[\p{{L}}\p{{M}}\p{{N}}]){_CJK_SCRIPTS}\p{{M}}*|{_WORD_CHAR}+(?:['’]{_WORD_CHAR}+)*",
    regex.VERSION1,
)


def _tokens(text: str):
    return list(_TOKEN_PATTERN.finditer(text))


def after_spoken_prefix(text: str, prefix: str) -> str | None:
    old = [m.group().casefold() for m in _tokens(prefix)]
    new = _tokens(text)
    if not old or [m.group().casefold() for m in new[:len(old)]] != old:
        return None
    return text[new[len(old)].start():].strip() if len(new) > len(old) else ''


def unspoken_extension(previous: str, revised: str, following: Sequence[str] = ()) -> str:
    old = [m.group().casefold() for m in _tokens(previous)]
    new = _tokens(revised)
    words = [m.group().casefold() for m in new]
    # Rewrites are not safe to replay. Only an aligned extension has a known
    # spoken prefix; punctuation and capitalization are immaterial to coverage.
    if not old or words[:len(old)] != old or len(words) <= len(old):
        return ""
    suffix = revised[new[len(old)].start():].strip()
    suffix_words = words[len(old):]
    later = [m.group().casefold() for text in following for m in _tokens(text)]
    if any(later[i:i + len(suffix_words)] == suffix_words
           for i in range(len(later) - len(suffix_words) + 1)):
        return ""
    return suffix
