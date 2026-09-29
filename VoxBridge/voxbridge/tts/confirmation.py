"""Revision-scoped English speech evidence, without model or audio work."""
from dataclasses import dataclass, field
import re
import time

from voxbridge.streaming.submission_policy import StableCandidate
from voxbridge.streaming.english_units import (
    english_boundary, content_key, boundary_key,
)


@dataclass
class _Evidence:
    words: StableCandidate = field(default_factory=StableCandidate)
    boundary: StableCandidate = field(default_factory=StableCandidate)
    text: str = ''


class SpeechConfirmation:
    def __init__(self, *, semantic_clauses: bool = True):
        self.semantic_clauses = semantic_clauses
        self._candidates: dict[object, _Evidence] = {}
        self._key = None
        self._observation = 0

    def reset(self) -> None:
        self._candidates.clear()
        self._key = None
        self._observation = 0

    def observe(self, texts: list[str], key: tuple[int, int] | None,
                *, identities: list[tuple[int, ...] | None] | None = None) -> None:
        if key is None:
            self.reset()
            return
        texts = texts[:64]
        keys = list(range(len(texts))) if identities is None else identities[:len(texts)]
        if key != self._key:
            self._observation += 1
            self._key = key
        for index in list(self._candidates):
            if index not in keys:
                del self._candidates[index]
        now = time.monotonic()
        for index, text in zip(keys, texts):
            if index is not None:
                evidence_key = key if identities is None else (0, self._observation)
                entry = self._candidates.setdefault(index, _Evidence())
                entry.words.observe(content_key(text), evidence_key, now)
                entry.boundary.observe(boundary_key(text), evidence_key, now)
                entry.text = text

    def _entry(self, text, identity):
        matches = [e for k, e in self._candidates.items()
                   if (identity is None or k == identity)
                   and e.boundary.text == boundary_key(text)]
        return min(matches, key=lambda e: min(e.words.hits, e.boundary.hits), default=None)

    def matches(self, text, observed):
        return boundary_key(text) == boundary_key(observed)

    def assessment(self, text: str, *, identity=None) -> dict:
        entry = self._entry(text, identity)
        word_hits = entry.words.hits if entry else 0
        boundary_hits = entry.boundary.hits if entry else 0
        now = time.monotonic()
        boundary = english_boundary(text)
        words = re.findall(r"[A-Za-z]+(?:['’][A-Za-z]+)?", text)
        sensitive = bool(re.search(r'\d', text)) or any(
            word.lower() in {'no', 'not', 'cannot', 'never', 'neither', 'nor', 'without', 'nobody', 'nothing', 'nowhere'}
            or word.lower().endswith(("n't", 'n’t')) for word in words)
        sensitive |= any(word[0].isupper() and word != 'I' for word in words[1:])
        required = 3 if sensitive or boundary.kind == 'clause' else 2
        reason = (boundary.reason or
                  ('terminal_boundary' if boundary.kind == 'clause' and not self.semantic_clauses else '') or
                  ('content_agreement' if word_hits < required else '') or
                  ('boundary_agreement' if boundary_hits < 2 else '') or 'ready')
        return dict(reason=reason, allow_urgent=(not sensitive if reason == 'ready' else None),
                    decode_hits=word_hits, boundary_hits=boundary_hits, required_hits=required,
                    source_age_ms=round(min(entry.words.age(now), entry.boundary.age(now)) * 1000) if entry else 0,
                    semantic_dependency=boundary.reason in {'semantic_dependency', 'open_word_tail', 'dependent_clause'},
                    boundary_kind=boundary.kind)

    def decision(self, text: str, *, identity: tuple[int, ...] | None = None) -> bool | None:
        return self.assessment(text, identity=identity)['allow_urgent']

    def evidence(self, text: str, identity: tuple[int, ...] | None) -> dict:
        details = self.assessment(text, identity=identity)
        return {key: details[key] for key in ('decode_hits', 'source_age_ms', 'semantic_dependency')}
