"""Bounded epoch-scoped PCM replay window; cursors never silently skip audio."""
from collections import deque
import base64
import time


class PCMError(ValueError):
    pass


class PCMInvalidCursor(PCMError):
    pass


class PCMEpochMismatch(PCMError):
    pass


class PCMCursorExpired(PCMError):
    pass


class NativePCMBuffer:
    def __init__(self, *, max_bytes: int = 16 * 1024 * 1024, max_chunks: int = 256):
        if max_bytes <= 0 or max_chunks <= 0:
            raise ValueError('PCM retention bounds must be positive')
        self.max_bytes = min(max_bytes, 16 * 1024 * 1024)
        self.max_chunks = min(max_chunks, 256)
        self.reset('')

    def reset(self, epoch: str):
        self.epoch = str(epoch)
        self._seq = 0
        self._bytes = 0
        self._chunks = deque()

    def append(self, *, pcm: bytes, sentence_id: str, revision: int,
               source_order: int, index: int, count: int, text: str):
        pcm = bytes(pcm)
        if not pcm or len(pcm) % 2 or len(pcm) > self.max_bytes:
            raise ValueError('invalid or oversized PCM16 chunk')
        if not 0 <= index < count:
            raise ValueError('invalid chunk index/count')
        self._seq += 1
        chunk = dict(seq=self._seq, sentence_id=sentence_id, revision=revision,
                     source_order=source_order, index=index, count=count,
                     sample_rate=24000, pcm=base64.b64encode(pcm).decode('ascii'),
                     duration_ms=max(1, round(len(pcm) * 1000 / 48000)), text=text,
                     created_at_ms=round(time.time() * 1000))
        self._chunks.append((chunk, len(pcm)))
        self._bytes += len(pcm)
        while self._bytes > self.max_bytes or len(self._chunks) > self.max_chunks:
            _, size = self._chunks.popleft()
            self._bytes -= size
        return dict(chunk)

    def snapshot(self, after: int, epoch: str | None = None) -> dict:
        if epoch is not None and epoch != self.epoch:
            raise PCMEpochMismatch('PCM epoch changed')
        if type(after) is not int or after < -1 or after > self._seq:
            raise PCMInvalidCursor('invalid PCM cursor')
        if after == -1:
            return dict(epoch=self.epoch, cursor=self._seq, chunks=[])
        floor = self._chunks[0][0]['seq'] - 1 if self._chunks else self._seq
        if after < floor:
            raise PCMCursorExpired('PCM cursor was evicted')
        chunks = [dict(chunk) for chunk, _ in self._chunks if chunk['seq'] > after][:4]
        return dict(epoch=self.epoch, cursor=chunks[-1]['seq'] if chunks else after, chunks=chunks)
