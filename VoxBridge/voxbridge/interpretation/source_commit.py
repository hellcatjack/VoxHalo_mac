"""Source coverage and speech evidence shared by the streaming orchestrator.

No translation, synthesis, timers, or audio publication happens here. An exact
revision still has to pass RevisionStableTTSBuffer at the first PCM commit.
"""
from dataclasses import dataclass
import re
from typing import Callable

from voxbridge.streaming.source_ledger import SourceLedger
from voxbridge.tts.confirmation import SpeechConfirmation
from voxbridge.streaming.english_units import independent_clause_start


@dataclass(frozen=True)
class CommitEvidence:
    reason: str
    allow_urgent: bool | None
    lookahead_tokens: int | None
    decode_hits: int
    source_age_ms: int
    semantic_dependency: bool
    boundary_hits: int
    required_hits: int
    boundary_kind: str


class SourceCommitCoordinator:
    def __init__(self):
        self.ledger = SourceLedger()
        self.confirmation = SpeechConfirmation()
        self._units = []

    def reset(self):
        self.ledger.reset()
        self.confirmation.reset()
        self._units = []

    def observe(self, text: str, *, raw: str, segment: int, carried: str,
                units: list[str], key: tuple[int, int] | None):
        self.ledger.observe(text, segment, raw=raw, carried=carried)
        spans = self.ledger.spans(units)
        self._units = list(zip(units, spans))
        identities = [span.tokens if self.ledger.observed_in_raw(span) else None for span in spans]
        self.confirmation.observe(units, key, identities=identities)

    def is_current(self, sentence_id: str, revision: int, source: str) -> bool:
        bound = self.ledger.binding(sentence_id, revision)
        return any(span is not None and bound is not None and span.tokens == bound.tokens
                   and self.confirmation.matches(source, text)
                   for text, span in self._units)

    def decision(self, sentence_id: str, revision: int, source: str, *,
                 count_tokens: Callable[[str], int | None], required_lookahead: int) -> CommitEvidence:
        span = self.ledger.current_span(self.ledger.binding(sentence_id, revision))
        identity = span.tokens if span else None
        assessment = self.confirmation.assessment(source, identity=identity)
        allow = assessment.pop('allow_urgent')
        if identity is None:
            allow = None
        following = re.sub(r'^[,;:.?!。！？\s\"”’\')\]}]+', '', self.ledger.text[span.end:]) if span else ''
        lookahead = count_tokens(following) if span else None
        reason = ('source_alignment' if span is None else
                  assessment['reason'] if allow is None else
                  'clause_continuation' if assessment['boundary_kind'] == 'clause'
                  and not independent_clause_start(following) else
                  'lookahead' if lookahead is None or lookahead < required_lookahead else 'ready')
        assessment.pop('reason')
        return CommitEvidence(reason, allow if reason == 'ready' else None, lookahead, **assessment)
