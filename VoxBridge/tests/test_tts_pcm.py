import pytest


def append(buffer, pcm=b'\x01\x00'):
    return buffer.append(pcm=pcm, sentence_id='s', revision=1, source_order=1, index=0, count=1, text='hello')


def test_retry_and_tail_join():
    from voxbridge.tts.pcm import NativePCMBuffer
    b = NativePCMBuffer(); b.reset('e'); append(b)
    first = b.snapshot(0, 'e')
    assert first == b.snapshot(0, 'e')
    assert first['chunks'][0]['pcm'] == 'AQA='
    assert first['cursor'] == 1
    assert b.snapshot(-1) == {'epoch': 'e', 'cursor': 1, 'chunks': []}


def test_cursor_errors_and_eviction():
    from voxbridge.tts.pcm import NativePCMBuffer, PCMInvalidCursor, PCMEpochMismatch, PCMCursorExpired
    b = NativePCMBuffer(max_chunks=2); b.reset('e')
    for _ in range(3): append(b)
    with pytest.raises(PCMCursorExpired): b.snapshot(0, 'e')
    with pytest.raises(PCMEpochMismatch): b.snapshot(1, 'old')
    for cursor in [-2, 4, True, 1.5]:
        with pytest.raises(PCMInvalidCursor): b.snapshot(cursor)
    b.reset('new')
    assert b.snapshot(0)['chunks'] == []


def test_buffer_bounds_and_batch():
    from voxbridge.tts.pcm import NativePCMBuffer
    b = NativePCMBuffer(max_bytes=8); b.reset('e')
    with pytest.raises(ValueError): append(b, b'0' * 10)
    with pytest.raises(ValueError): append(b, b'0')
    b = NativePCMBuffer(); b.reset('e')
    for _ in range(7): append(b)
    assert len(b.snapshot(0)['chunks']) == 4


@pytest.mark.parametrize('sentence_text', [None, '', 'Full sentence. 完整句子。'])
def test_sentence_metadata_is_additive_and_retained_on_retry(monkeypatch, sentence_text):
    import voxbridge.tts.pcm as pcm_module
    monkeypatch.setattr(pcm_module.time, 'time', lambda: 100.0)
    original = pcm_module.NativePCMBuffer(); original.reset('e')
    annotated = pcm_module.NativePCMBuffer(); annotated.reset('e')
    pcm = b'\x01\x00\xff\x7f\x00\x80'
    arguments = dict(pcm=pcm, sentence_id='s', revision=2, source_order=3,
                     index=0, count=2, text='Full sentence. ')
    expected = original.append(**arguments)
    published = annotated.append(**arguments, sentence_text=sentence_text)
    if sentence_text is None:
        assert published == expected
        assert 'sentence_text' not in published
    else:
        assert published.pop('sentence_text') == sentence_text
        assert published == expected
    first = annotated.snapshot(0, 'e')
    assert first == annotated.snapshot(0, 'e')
    if sentence_text is not None:
        assert first['chunks'][0]['sentence_text'] == sentence_text
        first['chunks'][0]['sentence_text'] = 'A later display correction.'
        assert annotated.snapshot(0, 'e')['chunks'][0]['sentence_text'] == sentence_text
    assert annotated.snapshot(-1, 'e') == original.snapshot(-1, 'e')
