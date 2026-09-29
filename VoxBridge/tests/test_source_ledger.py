from voxbridge.streaming.source_ledger import SourceLedger
from voxbridge.streaming.sentence_rules import _split_translation_units_and_tail
from voxbridge.tts.confirmation import SpeechConfirmation


def test_resegmented_occurrence_is_covered_but_real_repetition_is_not():
    ledger = SourceLedger()
    parent = 'The laws already exist, so why add more laws?'
    child = 'Why add more laws?'
    ledger.observe(parent, 1, raw=parent)
    whole, repeated = ledger.spans([parent, child])
    ledger.bind('first', 1, whole)
    ledger.publish('first', 1)
    assert ledger.covered_by(repeated) == 'first'
    text = parent + ' ' + child
    ledger.observe(text, 1, raw=text)
    whole, real_repeat = ledger.spans([parent, child])
    assert ledger.covered_by(real_repeat) is None
    ledger.observe(child, 2, raw=child)
    assert ledger.covered_by(ledger.spans([child])[0]) is None


def test_only_exact_explicit_carry_preserves_identity_across_windows():
    ledger = SourceLedger()
    prefix = "We don't need any"
    ledger.observe(prefix, 1, raw=prefix)
    old = ledger.spans([prefix])[0]
    ledger.observe(prefix + ' new regulations.', 2, raw='new regulations.', carried=prefix)
    combined = ledger.spans([prefix + ' new regulations.'])[0]
    assert combined.tokens[:len(old.tokens)] == old.tokens
    assert ledger.observed_in_raw(combined)
    assert not ledger.observed_in_raw(ledger.spans([prefix])[0])


def test_revisions_numbers_negation_and_apostrophes_are_not_deduplicated():
    ledger = SourceLedger()
    original = "We don't approve 1.5 million dollars."
    ledger.observe(original, 1, raw=original)
    old = ledger.spans([original])[0]
    ledger.bind('a', 1, old)
    ledger.publish('a', 1)
    for revised in ["We approve 1.5 million dollars.", "We don't approve 15 million dollars.",
                    "We don't approve 1,500 million dollars."]:
        ledger.observe(revised, 1, raw=revised)
        assert not ledger.contains(old)
        assert ledger.covered_by(ledger.spans([revised])[0]) is None


def test_real_chinese_repeats_keep_distinct_occurrences():
    ledger = SourceLedger()
    text = '这是我们的决定。这是我们的决定。'
    ledger.observe(text, 1, raw=text)
    a, b = ledger.spans(['这是我们的决定。'] * 2)
    ledger.bind('a', 1, a)
    assert ledger.covered_by(b) is None


def test_repaired_sentence_confirms_from_real_decodes_without_literal_substring():
    raw = "We don't need any. Any new regulations. The current laws already cover these concerns."
    units, tail = _split_translation_units_and_tail(raw)
    assert not tail
    assert len(units) == 2
    assert units[0] not in raw
    ledger, evidence = SourceLedger(), SpeechConfirmation()
    for chunk in (1, 1, 2, 3):
        ledger.observe(raw, 1, raw=raw)
        spans = ledger.spans(units)
        evidence.observe(units, (1, chunk), identities=[s.tokens for s in spans])
        assert evidence.decision(units[0], identity=spans[0].tokens) == (False if chunk == 3 else None)


def test_alignment_does_not_preserve_punctuation_agreement_or_withdrawn_text():
    ledger, evidence = SourceLedger(), SpeechConfirmation()
    for chunk, text in enumerate(['We can leave now.'] * 2 + ['We can leave now?'], 1):
        ledger.observe(text, 1, raw=text)
        span = ledger.spans([text])[0]
        evidence.observe([text], (1, chunk), identities=[span.tokens])
        assert evidence.decision(text, identity=span.tokens) == (True if chunk == 2 else None)
    evidence.observe([], (1, 4), identities=[])
    assert evidence.decision('We can leave now?') is None


def test_source_bindings_and_published_history_are_bounded():
    ledger = SourceLedger(max_bindings=4)
    for n in range(12):
        text = f'It costs {n} dollars.'
        ledger.observe(text, n, raw=text)
        ledger.bind(str(n), 1, ledger.spans([text])[0])
        ledger.publish(str(n), 1)
    assert len(ledger._bindings) == len(ledger._published) == 4


def test_dependency_repairs_preserve_subject_and_object_in_evaluation_cases():
    incomplete = ["We don't need any.", "They're asking to be.",
                  'I also have a lot of confidence in in,',
                  'The rules apply to food or air travel or.']
    for text in incomplete:
        units, tail = _split_translation_units_and_tail(text, target_latin_words=3)
        assert units == []
        assert tail
    raw = ("And so I'm empathetic. Empathetic to the enormous the enormity, of the challenges "
           "that they're dealing with, and I'm also, I also have a lot of confidence in in, "
           "the capabilities of the teams that they have.")
    units, tail = _split_translation_units_and_tail(raw)
    assert not tail
    assert not any(unit.endswith('confidence in in,') for unit in units)
    assert 'empathetic Empathetic to' in units[0]
    assert any('I also have a lot of confidence in in, the capabilities' in unit for unit in units)


def test_legitimate_complete_questions_and_stranded_prepositions_are_preserved():
    for text in ['Do you have any?', 'That is what it is for.', 'We need more time.',
                 "She said 'we can go' yesterday.", "The operator is 'and'."]:
        assert _split_translation_units_and_tail(text) == ([text], '')
