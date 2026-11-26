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


def unspoken_extension(previous: str, revised: str, following: Sequence[str] = (),
                       *, revised_tail_start: int | None = None) -> str:
    old = [m.group().casefold() for m in _tokens(previous)]
    new = _tokens(revised)
    words = [m.group().casefold() for m in new]
    # An edited prefix requires a boundary independently proved by the ledger.
    if old and words[:len(old)] == old and len(words) > len(old):
        revised_tail_start = new[len(old)].start()
    if revised_tail_start is None:
        return ""
    suffix = revised[revised_tail_start:].strip()
    suffix_words = [m.group().casefold() for m in _tokens(suffix)]
    later = [m.group().casefold() for text in following for m in _tokens(text)]
    if any(later[i:i + len(suffix_words)] == suffix_words
           for i in range(len(later) - len(suffix_words) + 1)):
        return ""
    return suffix
