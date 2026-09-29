"""Bounded source occurrence tracking, independent of translation and playback.

Token identities follow edits within one decoder window. Across windows only an
explicit carried tail can keep identities; identical speech in a new window is
otherwise a new occurrence. Coverage is never global string deduplication.
"""
from collections import OrderedDict
from dataclasses import dataclass
from difflib import SequenceMatcher

import regex


_TOKENS = regex.compile(
    r"\d+(?:[.,:/-]\d+)*|[\p{Han}\p{scx=Hiragana}\p{scx=Katakana}]|"
    r"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*", regex.VERSION1)


@dataclass(frozen=True)
class SourceSpan:
    tokens: tuple[int, ...]
    start: int
    end: int


class SourceLedger:
    def __init__(self, max_bindings: int = 256):
        self.max_bindings = max_bindings
        self.reset()

    def reset(self) -> None:
        self.text = ""
        self.segment = None
        self._words: list[str] = []
        self._ids: list[int] = []
        self._matches = []
        self._next_id = 0
        self._bindings = OrderedDict()
        self._published = OrderedDict()
        self._raw_start = 0

    def observe(self, text: str, segment: int, *, raw: str, carried: str = "") -> None:
        matches = list(_TOKENS.finditer(text))
        words = [m.group().casefold() for m in matches]
        ids = list(range(self._next_id, self._next_id + len(words)))
        self._next_id += len(words)
        if segment == self.segment:
            # Matching blocks are ordered occurrences, including real repeated
            # phrases. Never map an arbitrary equal sentence from the session.
            for block in SequenceMatcher(None, self._words, words, autojunk=False).get_matching_blocks():
                ids[block.b:block.b + block.size] = self._ids[block.a:block.a + block.size]
        elif carried:
            carry_words = [m.group().casefold() for m in _TOKENS.finditer(carried)]
            # The carry must be the exact old suffix and new prefix. A guessed
            # overlap, dropped word, or ambiguous rewrite starts fresh evidence.
            n = len(carry_words)
            if n and self._words[-n:] == carry_words and words[:n] == carry_words:
                ids[:n] = self._ids[-n:]
        raw_words = [m.group().casefold() for m in _TOKENS.finditer(raw)]
        self._raw_start = len(words)
        if raw_words and words[-len(raw_words):] == raw_words:
            self._raw_start = len(words) - len(raw_words)
        elif text == raw:
            self._raw_start = 0
        self.text, self.segment = text, segment
        self._words, self._ids, self._matches = words, ids, matches

    def spans(self, texts: list[str]) -> list[SourceSpan | None]:
        """Resolve occurrences in order; a unique fallback exposes resegmentation.

        The fallback can map an overlapping candidate back to an earlier range,
        but cannot decide which occurrence of a repeated phrase was intended.
        """
        result = []
        cursor = 0
        for text in texts:
            words = [m.group().casefold() for m in _TOKENS.finditer(text)]
            n = len(words)
            starts = [i for i in range(len(self._words) - n + 1)
                      if n and self._words[i:i + n] == words]
            start = next((i for i in starts if i >= cursor), None)
            if start is None and len(starts) == 1:
                start = starts[0]
            if start is None:
                result.append(None)
                continue
            end = start + n
            result.append(SourceSpan(tuple(self._ids[start:end]),
                                     self._matches[start].start(), self._matches[end - 1].end()))
            cursor = max(cursor, end)
        return result

    def observed_in_raw(self, span: SourceSpan | None) -> bool:
        # Repeated callbacks over a carried-only prefix are not fresh evidence.
        return bool(span and self._raw_start < len(self._matches)
                    and span.end > self._matches[self._raw_start].start())

    def bind(self, sentence_id: str, revision: int, span: SourceSpan | None) -> None:
        self._bindings.pop(sentence_id, None)
        if span is not None:
            self._bindings[sentence_id] = (revision, span)
        while len(self._bindings) > self.max_bindings:
            self._bindings.popitem(last=False)

    def binding(self, sentence_id: str, revision: int) -> SourceSpan | None:
        value = self._bindings.get(sentence_id)
        return value[1] if value and value[0] == revision else None

    def publish(self, sentence_id: str, revision: int) -> None:
        span = self.binding(sentence_id, revision)
        if span is not None:
            self._published[sentence_id] = span
        while len(self._published) > self.max_bindings:
            self._published.popitem(last=False)

    def covered_by(self, span: SourceSpan | None, *, excluding: str = "") -> str | None:
        if span is None:
            return None
        wanted = span.tokens
        entries = [(sid, entry[1]) for sid, entry in self._bindings.items()]
        entries.extend(self._published.items())
        for sid, known in entries:
            if sid == excluding:
                continue
            if any(known.tokens[i:i + len(wanted)] == wanted
                   for i in range(len(known.tokens) - len(wanted) + 1)):
                return sid
        return None

    def contains(self, span: SourceSpan | None) -> bool:
        return self.current_span(span) is not None

    def current_span(self, span: SourceSpan | None) -> SourceSpan | None:
        if span is not None:
            for i in range(len(self._ids) - len(span.tokens) + 1):
                if tuple(self._ids[i:i + len(span.tokens)]) == span.tokens:
                    return SourceSpan(span.tokens, self._matches[i].start(),
                                      self._matches[i + len(span.tokens) - 1].end())
        return None
