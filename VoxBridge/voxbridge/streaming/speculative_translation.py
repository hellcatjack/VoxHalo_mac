"""One exact-context preflight, with formal priority and cancellation-safe inference.

Factories perform computation only. Publication remains the caller's guarded
formal commit responsibility. No speculative work waits in the inference queue.
"""
import asyncio
from dataclasses import dataclass
from typing import Awaitable, Callable


@dataclass(frozen=True)
class TranslationKey:
    source: str
    direction: str
    source_language: str
    target_language: str
    generation: tuple[str, int]
    revision: int
    context: tuple


@dataclass
class _ResultUsage:
    """Account for one result only after every formal claim has settled."""
    trace: Callable | None = None
    claims: int = 0
    completed: bool = False
    invalidated: bool = False
    consumed: bool = False
    counted_waste: bool = False


class SpeculativeTranslation:
    def __init__(self):
        self._lock = asyncio.Lock()
        self._formal_count = 0
        self._tasks = set()
        self._candidate = None
        self._observation = None
        self._last_decode = None
        self._hits = 0
        self._since = 0.0
        self._last_offer = float('-inf')
        self._cache_key = None
        self.pending_task = None
        self._usage = None
        self.counters = dict(offers=0, hits=0, misses=0, wasted=0)

    @property
    def pending(self):
        return int(self.pending_task is not None and not self.pending_task.done())

    def invalidate(self, generation=None):
        if generation is None or (self._cache_key and self._cache_key.generation == generation):
            if self._usage is not None:
                self._usage.invalidated = True
                self._classify_usage(self._usage)
            if self.pending_task is not None and self.pending_task.done():
                self.pending_task = None
            self._cache_key = None
        if generation is None or (self._candidate and self._candidate.generation == generation):
            self._candidate = None
            self._observation = None
            self._hits = 0

    def _classify_usage(self, usage):
        if (usage.completed and usage.invalidated and not usage.claims
                and not usage.consumed and not usage.counted_waste):
            usage.counted_waste = True
            self.counters['wasted'] += 1
            if usage.trace:
                pending = 0 if usage is self._usage else self.pending
                usage.trace('translation_speculative_wasted', **self.counters, pending=pending)

    def _track(self, task):
        # Retain shielded computation even after its original caller is cancelled.
        self._tasks.add(task)
        def finished(done):
            self._tasks.discard(done)
            if not done.cancelled():
                done.exception()
        task.add_done_callback(finished)
        return task

    def offer(self, key: TranslationKey, factory: Callable[[], Awaitable[str]], *,
              observation: tuple[int, int] | None, now: float, complete: bool,
              formal_busy: bool = False, trace=None) -> bool:
        if key != self._candidate or not complete:
            self.invalidate()
            self._candidate = key if complete else None
            self._since = now
        if not complete or observation is None or type(observation[1]) is not int or observation[1] <= 0:
            return False
        decode = (key.generation, observation[0], observation[1])
        if self._last_decode and decode[:2] == self._last_decode[:2] and decode[2] <= self._last_decode[2]:
            return False
        self._last_decode = decode
        if self._observation and observation[0] != self._observation[0]:
            self.invalidate()
            self._candidate, self._since = key, now
        self._observation = observation
        if not self._hits:
            self._since = now
        self._hits += 1
        if (self._hits < 2 or now - self._since < .6 or now - self._last_offer < 1
                or formal_busy or self._formal_count or self._lock.locked()
                or self.pending or self._cache_key == key):
            return False
        self._last_offer, self._cache_key = now, key
        self.counters['offers'] += 1
        usage = self._usage = _ResultUsage(trace=trace)

        async def compute():
            # A formal request may have arrived before this new task gets CPU.
            if self._formal_count and self._cache_key != key:
                return ''
            async with self._lock:
                if self._cache_key != key:
                    return ''
                try:
                    value = await factory()
                except Exception:
                    value = ''
                usage.completed = True
                self._classify_usage(usage)
                return value
        self.pending_task = self._track(asyncio.create_task(compute()))
        if trace: trace('translation_speculative_offer', **self.counters, pending=self.pending)
        return True

    async def formal(self, key: TranslationKey | None, factory: Callable[[], Awaitable[str]], *, trace=None) -> str:
        self._formal_count += 1
        cached = self.pending_task if key is not None and self._cache_key == key else None
        usage = self._usage if cached is not None else None
        if usage is not None:
            usage.claims += 1
        if cached is None:
            self.invalidate()
        inference_started = False
        used_cache = False

        async def compute():
            nonlocal inference_started, used_cache
            if cached is not None:
                value = await asyncio.shield(cached)
                if value:
                    used_cache = True
                    if self.pending_task is cached:
                        self.pending_task, self._cache_key = None, None
                        usage.invalidated = True  # It no longer resides in the cache.
                    return value
            self.counters['misses'] += 1
            if trace: trace('translation_speculative_miss', **self.counters, pending=self.pending)
            async with self._lock:
                inference_started = True
                return await factory()

        task = self._track(asyncio.create_task(compute()))
        def finished(_):
            self._formal_count -= 1
        task.add_done_callback(finished)
        try:
            value = await asyncio.shield(task)
            if used_cache:
                usage.consumed = True
                self.counters['hits'] += 1
                if trace: trace('translation_speculative_hit', **self.counters, pending=self.pending)
            return value
        except asyncio.CancelledError:
            # Waiting work is cancellable; active to_thread inference is not.
            if not inference_started:
                task.cancel()
            raise
        finally:
            if usage is not None:
                usage.claims -= 1
                self._classify_usage(usage)
