"""Occurrence-scoped merges must preserve source coverage and speech fences."""
from dataclasses import replace

import pytest

from voxbridge.interpretation.source_commit import SourceCommitCoordinator, SourceCommitRow


FIRST = 'The developer remains responsible for these issues.'
SECOND = 'The issues affect their customers.'
MERGED = 'The developer remains responsible for these issues, the issues affect their customers.'


def pending_rows(coordinator, sources=(FIRST, SECOND)):
    text = ' '.join(sources)
    coordinator.observe(text, raw=text, segment=1, carried='', units=list(sources), key=(1, 1))
    rows = [SourceCommitRow(f'row-{i}', 1, 27 + i) for i in range(len(sources))]
    for row, span in zip(rows, coordinator.ledger.spans(list(sources))):
        coordinator.ledger.bind(row.sentence_id, row.revision, span)
    return rows


def observe_merge(coordinator, source=MERGED, *, segment=1, carried='', raw=None, key=None,
                  units=None):
    coordinator.observe(source, raw=source if raw is None else raw,
                        segment=segment, carried=carried,
                        units=[source] if units is None else units,
                        key=(segment, 2) if key is None else key)


def test_exact_merge_keeps_earliest_identity_and_order_without_mutating_evidence():
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    before = [coordinator.ledger.binding(row.sentence_id, row.revision) for row in rows]
    observe_merge(coordinator)
    [plan] = coordinator.reconciliation_plan(rows)
    assert plan.candidate_index == 0
    assert plan.source == MERGED
    assert plan.anchor == rows[0]
    assert plan.absorbed_rows == (rows[1],)
    assert plan.rows == tuple(rows)
    assert plan.span.tokens == before[0].tokens + before[1].tokens
    assert [coordinator.ledger.binding(row.sentence_id, row.revision) for row in rows] == before
    assert coordinator.confirmation.decision(MERGED, identity=plan.span.tokens) is None
    # The merge plan cannot turn an old unit's votes into votes for a new unit.
    coordinator.ledger.bind(plan.anchor.sentence_id, 2, plan.span)
    assert coordinator.decision(plan.anchor.sentence_id, 2, MERGED,
                                count_tokens=lambda text: 10, required_lookahead=5).reason == 'content_agreement'


def test_three_consecutive_rows_can_merge_without_losing_tokens():
    coordinator = SourceCommitCoordinator()
    third = 'They need to make reliable decisions.'
    rows = pending_rows(coordinator, (FIRST, SECOND, third))
    merged = MERGED[:-1] + ', they need to make reliable decisions.'
    observe_merge(coordinator, merged)
    [plan] = coordinator.reconciliation_plan(rows)
    assert plan.rows == tuple(rows)
    assert plan.span.tokens == tuple(token for row in rows
                                    for token in coordinator.ledger.binding(row.sentence_id, 1).tokens)


@pytest.mark.parametrize('fence', ['published', 'partial', 'has_addition'])
@pytest.mark.parametrize('row_index', [0, 1])
def test_any_orchestrator_publication_fence_rejects_merge(fence, row_index):
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    rows[row_index] = replace(rows[row_index], **{fence: True})
    observe_merge(coordinator)
    assert coordinator.reconciliation_plan(rows) == []


@pytest.mark.parametrize('row_index', [0, 1])
def test_published_ledger_intersection_cannot_be_hidden_by_row_metadata(row_index):
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    coordinator.ledger.publish(rows[row_index].sentence_id, rows[row_index].revision)
    observe_merge(coordinator)
    assert coordinator.reconciliation_plan(rows) == []


@pytest.mark.parametrize('source', [
    'The developer remains responsible for these issues, the issues affect customers.',
    'The developer remains responsible for these issues, and the issues affect their customers.',
    'The issues affect their customers, the developer remains responsible for these issues.',
    'The developer remains responsible for these issues, the issues affect their customers and partners.',
])
def test_deletions_insertions_reordering_and_extensions_fail_closed(source):
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    observe_merge(coordinator, source)
    assert coordinator.reconciliation_plan(rows) == []


def test_unknown_partial_overlap_or_interleaved_active_row_blocks_merge():
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    partial = coordinator.ledger.spans(['responsible for these issues'])[0]
    coordinator.ledger.bind('unknown', 1, partial)
    observe_merge(coordinator)
    assert coordinator.reconciliation_plan(rows) == []
    assert coordinator.ledger.unbind('unknown', 1)
    interleaved = SourceCommitRow('other-window', 1, 28)
    rows = [rows[0], interleaved, replace(rows[1], order=29)]
    assert coordinator.reconciliation_plan(rows) == []


def test_stale_revision_or_duplicate_identity_does_not_create_a_plan():
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    observe_merge(coordinator)
    assert coordinator.reconciliation_plan([replace(rows[0], revision=2), rows[1]]) == []
    assert coordinator.reconciliation_plan([rows[0], rows[0], rows[1]]) == []
    assert coordinator.reconciliation_plan(list(reversed(rows))) == []


def test_same_speech_in_a_new_decoder_window_is_a_new_occurrence():
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    observe_merge(coordinator, segment=2)
    assert coordinator.reconciliation_plan(rows) == []


def test_real_repeated_sentence_is_not_absorbed_from_a_later_occurrence():
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    full = MERGED + ' ' + SECOND
    observe_merge(coordinator, full, units=[MERGED, SECOND])
    [plan] = coordinator.reconciliation_plan(rows)
    repeated = coordinator.ledger.spans([MERGED, SECOND])[1]
    assert not set(plan.span.tokens).intersection(repeated.tokens)
    assert plan.rows == tuple(rows)


def test_ambiguous_overlapping_current_units_cannot_merge():
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    observe_merge(coordinator, units=[MERGED, SECOND])
    assert coordinator.reconciliation_plan(rows) == []


def test_carried_only_merge_plan_does_not_supply_fresh_decoder_evidence():
    coordinator = SourceCommitCoordinator()
    rows = pending_rows(coordinator)
    carried = FIRST + ' ' + SECOND
    following = 'The next speaker now explains what they mean.'
    full = MERGED + ' ' + following
    observe_merge(coordinator, full, segment=2, carried=carried, raw=following,
                  units=[MERGED, following])
    [plan] = coordinator.reconciliation_plan(rows)
    assert not coordinator.ledger.observed_in_raw(plan.span)
    coordinator.ledger.bind(plan.anchor.sentence_id, 2, plan.span)
    for chunk in (3, 4, 5):
        observe_merge(coordinator, full, segment=2, carried=carried, raw=following,
                      key=(2, chunk), units=[MERGED, following])
        evidence = coordinator.decision(plan.anchor.sentence_id, 2, MERGED,
                                        count_tokens=lambda text: 10, required_lookahead=5)
        assert evidence.reason == 'content_agreement'
        assert evidence.decode_hits == 0
        assert evidence.allow_urgent is None


def test_a_published_prefix_overlap_blocks_a_later_unpublished_subrange_merge():
    coordinator = SourceCommitCoordinator()
    prefix = 'The developer remains responsible for these issues, the issues'
    rows = pending_rows(coordinator)
    coordinator.ledger.bind('spoken-prefix', 1, coordinator.ledger.spans([prefix])[0])
    coordinator.ledger.publish('spoken-prefix', 1)
    coordinator.ledger.unbind('spoken-prefix', 1)
    observe_merge(coordinator)
    assert coordinator.reconciliation_plan(rows) == []
