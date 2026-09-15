import pytest


@pytest.mark.parametrize('text,expected', [
    ('The sixth day.', True),
    ('The total is 3.14.', True),
    ('He said, “The work is complete.”', True),
    ('He said, “The work is complete...', False),
    ('We were talking to Dr.', False),
    ('We were talking to Prof.', False),
    ('We have invited our guest speaker, “Dr.', False),
    ('We have invited our guest speaker, (Dr.', False),
    ('The guest uses the initial “J.', False),
    ('The initial is J.', False),
    ('We live in the U.S.', False),
    ('The total is 3.14', False),
    ('The next part is unfinished', False),
])
def test_english_period_endpoint_distinguishes_sentence_from_abbreviation(text, expected):
    from voxbridge.streaming.sentence_rules import english_period_endpoint
    assert english_period_endpoint(text) is expected
