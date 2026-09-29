import re

import pytest

from voxbridge.interpretation.source_commit import SourceCommitCoordinator
from voxbridge.streaming.english_units import english_boundary
from voxbridge.streaming.sentence_rules import _split_translation_units_and_tail
from voxbridge.tts.confirmation import SpeechConfirmation


def words(text):
    return re.findall(r"\d+(?:[.,]\d+)*|[A-Za-z]+(?:['’][A-Za-z]+)?", text)


@pytest.mark.parametrize('text', [
    'These tools work well,',
    'We have already completed the first stage of this important project,',
    "And so we've been working on this problem for a very long time,",
])
def test_closed_clause_has_shared_submission_and_speech_boundary(text):
    assert english_boundary(text).kind == 'clause'
    units, tail = _split_translation_units_and_tail(text, target_latin_words=3)
    assert units == [text] and tail == ''
    evidence = SpeechConfirmation()
    for n in range(1, 4):
        evidence.observe([text], (1, n))
        assert evidence.decision(text) == (True if n == 3 else None)


@pytest.mark.parametrize('text', [
    'If the product fails,', 'Because the system has already failed today,',
    'We do not need any,', 'I have confidence in,',
    'We have developed tools for food or travel or,',
    'The results of our long running experiments,',
    'We know that,', 'The total is 1,500,',
    'He said "the work is complete,',
    'We have already been,', 'We will explain that,',
    'The total is -1,500,', '2026.',
])
def test_dependent_or_ambiguous_clauses_are_retained_never_dropped(text):
    assert english_boundary(text).kind == 'open'
    units, tail = _split_translation_units_and_tail(text, target_latin_words=3)
    assert words(' '.join([*units, tail])) == words(text)
    evidence = SpeechConfirmation()
    for n in range(20): evidence.observe([text], (1, n))
    assert evidence.decision(text) is None


def test_punctuation_edit_preserves_word_history_but_rechecks_boundary():
    evidence = SpeechConfirmation()
    before = 'We should not leave this place, yet.'
    after = 'We should not leave this place yet.'
    for n, text in enumerate([before, before, after, after], 1):
        evidence.observe([text], (1, n))
        a = evidence.assessment(text)
        assert a['decode_hits'] == n
        assert a['boundary_hits'] == (n if n <= 2 else n - 2)
        assert evidence.decision(text) == (False if n == 4 else None)


@pytest.mark.parametrize('changed', [
    'We can approve 1.5 million dollars.',
    'We cannot approve 15 million dollars.',
    'We cannot approve 1,500 million dollars.',
])
def test_content_risk_changes_reset_both_evidence_tracks(changed):
    evidence = SpeechConfirmation()
    for n in range(1, 4): evidence.observe(['We cannot approve 1.5 million dollars.'], (1, n))
    evidence.observe([changed], (1, 4))
    assert evidence.assessment(changed)['decode_hits'] == 1
    assert evidence.decision(changed) is None


def test_quote_scope_change_cannot_reuse_boundary_confirmation():
    evidence = SpeechConfirmation()
    a = 'She said "we should go now".'
    b = 'She said we "should go now".'
    for n in range(1, 3): evidence.observe([a], (1, n))
    evidence.observe([b], (1, 3))
    assert evidence.assessment(b)['boundary_hits'] == 1
    assert evidence.decision(b) is None


@pytest.mark.parametrize('tail,expected', [
    ('and we have already started the next stage of the project.', 'ready'),
    ('which were designed to be used in the following cases.', 'clause_continuation'),
    ('because the speaker has not yet completed this thought.', 'clause_continuation'),
    ('and we have', 'lookahead'),
])
def test_clause_requires_independent_following_context_and_occurrence_identity(tail, expected):
    prefix = 'We have completed the first stage of the project,'
    c = SourceCommitCoordinator()
    text = prefix + ' ' + tail
    for chunk in range(1, 4):
        c.observe(text, raw=text, segment=1, carried='', units=[prefix], key=(1, chunk))
        c.ledger.bind('first', 1, c.ledger.spans([prefix])[0])
    result = c.decision('first', 1, prefix, count_tokens=lambda s: len(words(s)), required_lookahead=5)
    assert result.reason == expected
    assert result.allow_urgent == (True if expected == 'ready' else None)


@pytest.mark.parametrize('text', [
    'If the product fails, we will repair it, and we will explain the result.',
    'We have completed the first stage, which includes the first important test, and we can proceed.',
    'We do not need any, any new regulations. We have sufficient rules already.',
    'We have confidence in, the capabilities of our teams. They are ready.',
    'We have done the work, we have done the work, and we have checked every result.',
])
@pytest.mark.parametrize('target', [3, 8, 16, 24])
def test_resegmentation_conserves_every_source_word_including_repetitions(text, target):
    units, tail = _split_translation_units_and_tail(text, target_latin_words=target)
    assert words(' '.join([*units, tail])) == words(text)
