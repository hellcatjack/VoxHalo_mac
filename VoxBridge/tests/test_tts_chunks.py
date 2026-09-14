import pytest


def test_chunks_retain_every_character_and_cap_words():
    from voxbridge.tts.chunks import split_speech_chunks
    text = 'Dr. Smith paid $3.14 for this useful book, and then ' + ' '.join(f'word{i}' for i in range(40)) + '.'
    chunks = split_speech_chunks(text, 'English')
    assert ''.join(chunks) == text
    assert 8 <= len(chunks[0].split()) <= 16
    assert all(len(c.split()) <= 18 for c in chunks)
    assert chunks[0].startswith('Dr. Smith paid $3.14')


def test_chinese_chunks_retain_punctuation():
    from voxbridge.tts.chunks import split_speech_chunks
    text = '今天我們一起來敬拜神，並且聆聽祂的話語。' * 10
    chunks = split_speech_chunks(text, 'Chinese')
    assert ''.join(chunks) == text
    assert len(chunks) > 1
    assert chunks == ('今天我們一起來敬拜神，並且聆聽祂的話語。',) * 10


@pytest.mark.parametrize('language', ['Chinese', 'zh', '中文'])
@pytest.mark.parametrize('text', [
    '我们今天一起学习神的话语，并且思想这些教导怎样帮助我们在家庭和教会生活中彼此扶持，在困难的时候仍然带着信心继续前行。',
    '当我们一同学习神的话语时，不仅要明白经文原本的意思，也要思想这些教导怎样影响我们的家庭和教会生活，让我们在面对困难的时候仍然能够彼此扶持，并且带着信心继续前行。',
    '我们应当认真思想这些经文如何帮助每一位弟兄姐妹在日常生活中带着信心面对眼前的困难并且持续学习彼此扶持和彼此相爱的功课。',
])
def test_chinese_listening_samples_keep_whole_sentence(text, language):
    from voxbridge.tts.chunks import split_speech_chunks
    assert split_speech_chunks(text, language) == (text,)


def test_chinese_sentence_boundaries_keep_quotes_numbers_and_english_words():
    from voxbridge.tts.chunks import split_speech_chunks
    sentences = ('  他说：“请参考 Dr. Smith 的 John 3:16，价格是 3.14 美元。”\n',
                 '我们准备好了吗？！ ” ', '让我们一起祷告. ', 'Amen')
    assert split_speech_chunks(''.join(sentences), 'Chinese') == sentences


def test_overlong_chinese_uses_last_clause_boundary():
    from voxbridge.tts.chunks import split_speech_chunks
    first = '我们相信，' + '弟兄姐妹在日常生活中彼此扶持' * 6 + '，'
    last = '并且带着信心继续前行' * 5 + '。'
    assert split_speech_chunks(first + last, 'Chinese') == (first, last)


def test_overlong_unpunctuated_chinese_does_not_cut_a_word():
    from voxbridge.tts.chunks import split_speech_chunks
    text = '我们应当彼此扶持' * 20 + '。'
    chunks = split_speech_chunks(text, 'Chinese')
    assert ''.join(chunks) == text
    assert all(len(chunk) <= 120 for chunk in chunks)
    # The 120-character boundary lands inside 扶持.
    assert all(not chunk.endswith('扶') for chunk in chunks[:-1])


@pytest.mark.parametrize('ending', ['。', '。”\n', '？！ 」 ', '   '])
def test_chinese_limit_does_not_create_punctuation_only_tail(ending):
    from voxbridge.tts.chunks import split_speech_chunks
    text = '我们' * 60 + ending
    assert split_speech_chunks(text, 'Chinese') == (text,)


@pytest.mark.parametrize('prefix, reference', [
    ('我们一同学习神的话语并彼此扶持' * 6 + '请读约翰福音', '3:16'),
    ('我们' * 55 + '会议开始时间', '12:30'),
    ('我们' * 59, '12:30'),
])
def test_overlong_chinese_keeps_bible_references_and_times(prefix, reference):
    from voxbridge.tts.chunks import split_speech_chunks
    text = prefix + reference + '并认真思想这些经文对于日常生活的意义和应用。'
    chunks = split_speech_chunks(text, 'Chinese')
    assert ''.join(chunks) == text
    assert any(reference in chunk for chunk in chunks)


@pytest.mark.parametrize('text', ['', '   ', '\n\t'])
def test_chinese_blank_text_has_no_audio_chunks(text):
    from voxbridge.tts.chunks import split_speech_chunks
    assert split_speech_chunks(text, 'Chinese') == ()


def test_english_sentence_boundary_is_preferred():
    from voxbridge.tts.chunks import split_speech_chunks
    text = 'One two three four five six seven eight. Nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty.'
    assert split_speech_chunks(text, 'en')[0] == 'One two three four five six seven eight. '
