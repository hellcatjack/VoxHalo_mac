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
