import re

import pytest

from voxbridge.streaming.short_units import group_short_units, split_short_units
from voxbridge.streaming.sentence_rules import _split_translation_units_and_tail


@pytest.mark.parametrize('units', [
    ['They agreed.', 'We continued.', 'It worked.'],
    ['We cannot.', 'We will not.', 'We must not.'],
    ['No.', 'No.', 'We will continue with the original plan.'],
    ['Why?', 'It worked.', 'Thank you.'],
    ['I paid 1,234.56 dollars.', "Don't lose the decimal."],
    ['我们同意。', '继续执行。', '我们同意。'],
])
def test_grouping_preserves_all_occurrences(units):
    compact = lambda value: re.sub(r'\s+', '', value)
    assert compact(''.join(group_short_units(units))) == compact(''.join(units))


def test_neighboring_short_units_share_translation_context_without_waiting():
    assert group_short_units(['They agreed.', 'We continued.', 'It worked.']) == [
        'They agreed. We continued. It worked.']
    assert group_short_units(['Thank you.', 'They agreed.']) == ['Thank you.', 'They agreed.']
    assert group_short_units(['Stop!', 'We continued.']) == ['Stop!', 'We continued.']


def test_submitted_boundary_does_not_change_when_following_text_arrives():
    units, tail = split_short_units('They agreed. We continued. It worked. They stopped. Still talking',
                                   splitter=_split_translation_units_and_tail, locked=['They agreed.'])
    assert units == ['They agreed.', 'We continued. It worked.', 'They stopped.']
    assert tail == 'Still talking'


def test_changed_prefix_defers_to_existing_revision_reconciler():
    text = 'They disagreed. We continued. Unfinished'
    assert split_short_units(text, splitter=_split_translation_units_and_tail, locked=['They agreed.']) == _split_translation_units_and_tail(text)


def test_final_complete_short_sentence_is_never_held_for_length():
    assert split_short_units('Thank you.', splitter=_split_translation_units_and_tail, locked=[]) == (['Thank you.'], '')


def test_newest_unit_remains_separate_for_existing_confirmation_lookahead():
    assert split_short_units('They agreed. We continued. Still talking',
                             splitter=_split_translation_units_and_tail, locked=[]) == (
        ['They agreed.', 'We continued.'], 'Still talking')


def test_grouped_source_revision_preserves_whole_input_and_tail():
    old = 'They agreed. We succeeded. It worked.'
    initial, tail = split_short_units(old, splitter=_split_translation_units_and_tail, locked=[])
    assert initial == ['They agreed. We succeeded.', 'It worked.']
    corrected = 'They agreed. We did not succeed. It worked. Final tail'
    units, tail = split_short_units(corrected, splitter=_split_translation_units_and_tail, locked=initial[:1])
    compact = lambda text: re.sub(r'\s+', '', text)
    assert compact(''.join(units) + tail) == compact(corrected)
    assert 'not' in ' '.join(units)


def test_open_complement_is_not_translated_as_an_independent_short_sentence():
    units, tail = split_short_units('We have confidence in. Our teams. They are ready.',
                                   splitter=_split_translation_units_and_tail, locked=[])
    assert units == ['We have confidence in Our teams.', 'They are ready.']
    assert tail == ''
