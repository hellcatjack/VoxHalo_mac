"""Conservative assembly of unregistered discourse fragments after hard cuts."""
import re

import pytest

from voxbridge.interpretation.source_commit import SourceCommitCoordinator
from voxbridge.streaming.semantic_units import repair_carried_discourse_units


def _words(text):
    return re.findall(r"[a-z]+(?:['’][a-z]+)?", text.lower())


@pytest.mark.parametrize('fragment', [
    'Yeah Well, first of all.', 'Well, first.', 'So, secondly.',
    'Okay, first of all.', 'Yeah, well, first.',
])
def test_carried_discourse_fragment_joins_only_its_fresh_completed_neighbour(fragment):
    neighbour = 'we need to discuss the current challenges.'
    following = 'the next sentence remains separate.'
    units, tail = repair_carried_discourse_units(
        [fragment, neighbour, following], '', carried_unit_indexes={0},
    )
    assert units == [fragment.removesuffix('.') + ' ' + neighbour, following]
    assert tail == ''
    assert _words(' '.join(units)) == _words(' '.join([fragment, neighbour, following]))


def test_carried_fragment_with_only_a_fresh_incomplete_tail_is_kept_pending():
    fragment = 'Yeah Well, first of all.'
    units, tail = repair_carried_discourse_units(
        [fragment], 'we are still discussing the', carried_unit_indexes={0},
    )
    assert units == []
    assert tail == 'Yeah Well, first of all we are still discussing the'
    assert _words(tail) == _words(fragment + ' we are still discussing the')
    assert repair_carried_discourse_units(
        [fragment], '', carried_unit_indexes={0},
    ) == ([], fragment.removesuffix('.'))


def test_complete_fragment_does_not_merge_without_explicit_carried_occurrence():
    sentences = ['Well, first.', 'we need to discuss the current challenges.']
    assert repair_carried_discourse_units(
        sentences, '', carried_unit_indexes=set(),
    ) == (sentences, '')
    assert repair_carried_discourse_units(
        sentences, '', carried_unit_indexes={0}, unregistered_start=1,
    ) == (sentences, '')


def test_only_the_unregistered_suffix_is_assembled():
    sentences = ['Well, first.', 'the old point was complete.',
                 'So, secondly.', 'we can discuss the next point.']
    original = list(sentences)
    assert repair_carried_discourse_units(
        sentences, 'an unfinished tail', carried_unit_indexes={0, 2}, unregistered_start=2,
    ) == ([sentences[0], sentences[1], 'So, secondly we can discuss the next point.'],
          'an unfinished tail')
    assert sentences == original


@pytest.mark.parametrize('short_sentence', [
    'I think so.', 'It worked.', 'Yes.', 'No.', 'Thank you.', 'Stop!',
    'First?', 'Well, first?', 'Okay, first!', 'First of all.', 'Well.',
    'Well, first we need to discuss this.', 'So, secondly we can leave.',
])
def test_legitimate_short_sentences_and_complete_clauses_are_unchanged(short_sentence):
    sentences = [short_sentence, 'we can discuss the next point.']
    assert repair_carried_discourse_units(
        sentences, '', carried_unit_indexes={0},
    ) == (sentences, '')


def test_real_repetition_in_fresh_speech_retains_both_occurrences():
    carried = 'Well, first.'
    fresh = 'well, first, we need to discuss this.'
    units, tail = repair_carried_discourse_units(
        [carried, fresh], '', carried_unit_indexes={0},
    )
    assert units == ['Well, first well, first, we need to discuss this.']
    assert tail == ''
    assert _words(' '.join(units)) == _words(carried + ' ' + fresh)
    assert _words(' '.join(units)).count('first') == 2


def test_fragment_does_not_move_across_a_different_complete_carried_sentence():
    sentences = ['Well, first.', 'the old point was complete.',
                 'we can discuss the next point.']
    assert repair_carried_discourse_units(
        sentences, '', carried_unit_indexes={0, 1},
    ) == (sentences, '')


def test_adjacent_carried_fragments_preserve_every_word_before_fresh_speech():
    sentences = ['Well, first.', 'So, secondly.', 'we can leave now.']
    units, tail = repair_carried_discourse_units(
        sentences, '', carried_unit_indexes={0, 1},
    )
    assert units == ['Well, first So, secondly we can leave now.']
    assert tail == ''
    assert _words(' '.join(units)) == _words(' '.join(sentences))


def test_assembly_retains_an_incomplete_semantic_complement_in_the_tail():
    sentences = ['Well, first.', 'we need any.']
    units, tail = repair_carried_discourse_units(
        sentences, 'new regulations', carried_unit_indexes={0},
    )
    assert units == []
    assert tail == 'Well, first we need any new regulations'
    assert _words(tail) == _words(' '.join(sentences) + ' new regulations')


def test_chinese_units_and_tail_are_unchanged():
    sentences = ['第一点。', '我们应该认真讨论当前的问题。']
    assert repair_carried_discourse_units(
        sentences, '而且需要继续', carried_unit_indexes={0, 1},
    ) == (sentences, '而且需要继续')


def test_pure_carry_never_adds_hits_and_assembled_unit_requires_new_real_decodes():
    fragment = 'Well, first.'
    coordinator = SourceCommitCoordinator()
    coordinator.observe(fragment, raw=fragment, segment=1, carried='',
                        units=[fragment], key=(1, 1))
    old_span = coordinator.ledger.spans([fragment])[0]

    units, tail = repair_carried_discourse_units(
        [fragment], '', carried_unit_indexes={0},
    )
    assert units == [] and tail == fragment.removesuffix('.')
    for chunk in range(1, 8):
        coordinator.observe(fragment, raw='', segment=2, carried=fragment,
                            units=units, key=(2, chunk))
        assert coordinator.confirmation.assessment(fragment)['decode_hits'] == 0

    neighbour = 'we can leave now.'
    following = 'the next sentence provides enough context to continue.'
    raw = neighbour + ' ' + following
    effective = fragment + ' ' + raw
    units, tail = repair_carried_discourse_units(
        [fragment, neighbour, following], '', carried_unit_indexes={0},
    )
    merged = units[0]
    for chunk, expected_hits in [(8, 1), (8, 1), (9, 2)]:
        coordinator.observe(effective, raw=raw, segment=2, carried=fragment,
                            units=units, key=(2, chunk))
        span = coordinator.ledger.spans([merged])[0]
        coordinator.ledger.bind('merged', 1, span)
        assert span.tokens[:len(old_span.tokens)] == old_span.tokens
        details = coordinator.confirmation.assessment(merged, identity=span.tokens)
        assert details['decode_hits'] == expected_hits
        assert details['allow_urgent'] == (True if expected_hits == 2 else None)
    evidence = coordinator.decision('merged', 1, merged,
                                    count_tokens=lambda text: len(_words(text)),
                                    required_lookahead=5)
    assert evidence.reason == 'ready'
    assert evidence.decode_hits == evidence.boundary_hits == 2
