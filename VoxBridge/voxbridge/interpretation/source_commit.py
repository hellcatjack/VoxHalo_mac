"""Source coverage and speech evidence shared by the streaming orchestrator.

No translation, synthesis, timers, or audio publication happens here. An exact
revision still has to pass RevisionStableTTSBuffer at the first PCM commit.
"""
from dataclasses import dataclass
import re
from typing import Callable

from voxbridge.streaming.source_ledger import SourceLedger, SourceSpan
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


@dataclass(frozen=True)
class SourceCommitRow:
    """Snapshot of a source row and the fences owned by its orchestrator."""

    sentence_id: str
    revision: int
    order: int
    published: bool = False
    partial: bool = False
    has_addition: bool = False


@dataclass(frozen=True)
class SourceReconciliation:
    """A complete current unit replacing consecutive, wholly unpublished rows.

    The caller must recheck these revisions and fences before applying the plan
    atomically. Its first row keeps its sentence ID and publication order;
    absorbed rows become terminal only when that replacement is registered.
    This is coverage bookkeeping, never a speech-confirmation vote.
    """

    candidate_index: int
    source: str
    span: SourceSpan
    anchor: SourceCommitRow
    absorbed_rows: tuple[SourceCommitRow, ...]

    @property
    def rows(self) -> tuple[SourceCommitRow, ...]:
        return (self.anchor, *self.absorbed_rows)


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

    def reconciliation_plan(self, rows: list[SourceCommitRow]) -> list[SourceReconciliation]:
        """Plan only exact many-to-one occurrence merges in current complete units.

        Rows must describe the full active source order. Missing metadata,
        interleaved rows, partial coverage, new words, and published intersections
        fail closed. Decoder segmentation may change punctuation, but every old
        occurrence token must remain, exactly once and in the original order.
        No binding or confirmation state is changed by calculating a plan.
        """
        if (len({row.sentence_id for row in rows}) != len(rows)
                or any(a.order >= b.order for a, b in zip(rows, rows[1:]))):
            return []
        positions = {row.sentence_id: i for i, row in enumerate(rows)}
        by_id = {row.sentence_id: row for row in rows}
        plans = []
        for index, (source, span) in enumerate(self._units):
            if span is None or self.ledger.overlaps_published(span):
                continue
            wanted = set(span.tokens)
            # A unique fallback in spans() can expose overlapping candidates.
            # It does not establish that either segmentation owns the overlap.
            if any(other is not None and wanted.intersection(other.tokens)
                   for j, (_, other) in enumerate(self._units) if j != index):
                continue
            overlaps = self.ledger.overlapping_bindings(span)
            if len(overlaps) < 2 or any(sid not in by_id for sid, _, _ in overlaps):
                continue
            overlaps.sort(key=lambda entry: positions[entry[0]])
            row_positions = [positions[sid] for sid, _, _ in overlaps]
            if row_positions != list(range(row_positions[0], row_positions[-1] + 1)):
                continue
            covered_rows = tuple(by_id[sid] for sid, _, _ in overlaps)
            if any(row.published or row.partial or row.has_addition
                   or row.revision != revision
                   for row, (_, revision, _) in zip(covered_rows, overlaps)):
                continue
            old_tokens = tuple(token for _, _, bound in overlaps for token in bound.tokens)
            if old_tokens != span.tokens:
                continue
            if any(self.ledger.current_span(bound) is None for _, _, bound in overlaps):
                continue
            plans.append(SourceReconciliation(index, source, span, covered_rows[0], covered_rows[1:]))
        return plans

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
