from voxbridge.tts.confirmation import SpeechConfirmation


def test_only_new_decodes_confirm_a_complete_sentence():
    evidence = SpeechConfirmation()
    sentence = 'The weather is pleasant today.'
    for _ in range(10):
        evidence.observe([sentence], (1, 1))
    assert evidence.decision(sentence) is None
    evidence.observe([sentence], (1, 2))
    assert evidence.decision(sentence) is True
    evidence.observe(['The weather is unpleasant today.'], (1, 3))
    assert evidence.decision(sentence) is None
    assert evidence.decision('The weather is unpleasant today.') is None


def test_sensitive_sentence_needs_more_agreement_and_cannot_use_urgent_shortcut():
    for sentence in ['The total is 15 dollars.', 'We should not leave yet.', 'We cannot approve the transfer.', 'We met David outside.']:
        evidence = SpeechConfirmation()
        evidence.observe([sentence], (1, 1))
        evidence.observe([sentence], (1, 2))
        assert evidence.decision(sentence) is None
        evidence.observe([sentence], (1, 3))
        assert evidence.decision(sentence) is False


def test_open_clause_and_missing_decode_evidence_wait_for_final_source():
    for sentence in ['We decided to.', 'If the train is late.', 'He said "we should go.', 'The total is']:
        evidence = SpeechConfirmation()
        for chunk in range(1, 5):
            evidence.observe([sentence], (1, chunk))
        assert evidence.decision(sentence) is None
    evidence = SpeechConfirmation()
    for _ in range(5):
        evidence.observe(['We can leave now.'], None)
    assert evidence.decision('We can leave now.') is None


def test_confirmation_does_not_cross_segments_or_reused_candidate_positions():
    evidence = SpeechConfirmation()
    sentence = 'The weather is pleasant today.'
    evidence.observe([sentence], (1, 1))
    evidence.observe([sentence], (1, 2))
    assert evidence.decision(sentence) is True
    evidence.observe([sentence], (2, 1))
    assert evidence.decision(sentence) is None
