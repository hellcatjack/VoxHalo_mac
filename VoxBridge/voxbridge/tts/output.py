"""Speech publication port; transport commit semantics remain with the publisher."""
from typing import Protocol
from .jobs import TTSReadyItem


class SpeechStatus(Protocol):
    speech_epoch_id: str
    queue_depth: int
    preparation_queue_depth: int
    prepared_audio_count: int


class SpeechOutput(Protocol):
    @property
    def status(self) -> SpeechStatus: ...
    @property
    def listener_count(self) -> int: ...
    async def prepare(self, item: TTSReadyItem) -> bool: ...
    async def publish(self, item: TTSReadyItem) -> bool: ...
    def begin_source_generation(self) -> None: ...
    async def discard_idle_backlog(self) -> int: ...


class SharedSpeechOutput:
    """Bridge the existing atomic PCM/HLS publisher without copying or rescheduling PCM."""
    def __init__(self, publisher):
        self._publisher = publisher

    @property
    def status(self):
        return self._publisher.status

    @property
    def listener_count(self) -> int:
        return self._publisher.listener_count

    async def prepare(self, item: TTSReadyItem) -> bool:
        return await self._publisher.prepare(item)

    async def publish(self, item: TTSReadyItem) -> bool:
        return await self._publisher.publish(item)

    def begin_source_generation(self) -> None:
        self._publisher.begin_source_generation()

    async def discard_idle_backlog(self) -> int:
        return await self._publisher.discard_idle_backlog()
