import asyncio
from dataclasses import replace

import pytest

from voxbridge.streaming import speculative_translation as speculative


def key(**changes):
    return replace(speculative.TranslationKey(
        source='愿主赐福给你。', direction='zh2en', source_language='Chinese',
        target_language='English', generation=('stream-a', 1), revision=1,
        context=('full church prompt', 'strict church prompt', 'hy-mt', 'mac-verified', 256),
    ), **changes)


async def result():
    return 'May the Lord bless you.'


def offer(cache, wanted, factory=result, *, chunk=2, now=1, busy=False):
    return cache.offer(wanted, factory, observation=(1, chunk), now=now,
                       complete=True, formal_busy=busy)


@pytest.mark.asyncio
async def test_distinct_decodes_age_and_exact_completed_hit():
    cache = speculative.SpeculativeTranslation()
    assert not offer(cache, key(), chunk=1, now=0)
    assert not offer(cache, key(), chunk=1, now=1)
    assert offer(cache, key(), chunk=2, now=1)
    await cache.pending_task
    async def forbidden():
        raise AssertionError('exact completed hit must not run inference again')
    assert await cache.formal(key(), forbidden) == 'May the Lord bless you.'
    assert cache.counters['hits'] == 1
    assert cache.pending == 0


@pytest.mark.parametrize('changes', [
    {'source': '愿主赐福给我们。'}, {'direction': 'en2zh'},
    {'source_language': '中文'}, {'target_language': 'French'},
    {'generation': ('stream-b', 1)}, {'generation': ('stream-a', 2)},
    {'revision': 2}, {'context': ('different prompt',)},
    {'context': ('full church prompt', 'strict church prompt', 'hy-mt', 'default', 256)},
])
@pytest.mark.asyncio
async def test_mismatch_never_reuses_result(changes):
    cache = speculative.SpeculativeTranslation()
    offer(cache, key(), chunk=1, now=0)
    offer(cache, key(), now=1)
    await cache.pending_task
    async def fresh(): return 'Fresh translation'
    assert await cache.formal(key(**changes), fresh) == 'Fresh translation'
    assert cache.counters['misses'] == 1


@pytest.mark.asyncio
async def test_formal_joins_matching_running_speculation():
    cache = speculative.SpeculativeTranslation()
    started, release = asyncio.Event(), asyncio.Event()
    async def blocked():
        started.set()
        await release.wait()
        return 'joined'
    offer(cache, key(), blocked, chunk=1, now=0)
    assert offer(cache, key(), blocked, now=1)
    await started.wait()
    formal = asyncio.create_task(cache.formal(key(), result))
    await asyncio.sleep(0)
    release.set()
    assert await formal == 'joined'
    assert cache.counters['hits'] == 1


@pytest.mark.asyncio
async def test_cancelled_formal_does_not_release_running_inference_and_formal_has_priority():
    cache = speculative.SpeculativeTranslation()
    started, release, second_started = asyncio.Event(), asyncio.Event(), asyncio.Event()
    async def blocked():
        started.set()
        await release.wait()
        return 'old'
    first = asyncio.create_task(cache.formal(key(), blocked))
    await started.wait()
    first.cancel()
    with pytest.raises(asyncio.CancelledError): await first
    async def second():
        second_started.set()
        return 'second'
    waiting = asyncio.create_task(cache.formal(key(revision=2), second))
    await asyncio.sleep(0)
    offer(cache, key(), chunk=1, now=0)
    assert not offer(cache, key(), now=1)
    assert not second_started.is_set()
    release.set()
    assert await waiting == 'second'


@pytest.mark.asyncio
async def test_stale_completion_is_waste_and_never_reused_or_queued():
    cache = speculative.SpeculativeTranslation()
    started, release = asyncio.Event(), asyncio.Event()
    async def blocked():
        started.set()
        await release.wait()
        return 'obsolete'
    offer(cache, key(), blocked, chunk=1, now=0)
    offer(cache, key(), blocked, now=1)
    task = cache.pending_task
    await started.wait()
    assert not offer(cache, key(source='新句子。'), chunk=3, now=2)
    assert not offer(cache, key(source='新句子。'), chunk=4, now=3)
    release.set()
    await task
    assert cache.counters['wasted'] == 1
    assert await cache.formal(key(), result) == 'May the Lord bless you.'


@pytest.mark.asyncio
async def test_natural_boundary_age_busy_and_debounce_gate():
    cache = speculative.SpeculativeTranslation()
    assert not cache.offer(key(), result, observation=(1, 1), now=0, complete=False)
    assert not offer(cache, key(), chunk=2, now=1)
    assert not offer(cache, key(), chunk=3, now=1.5)
    assert not offer(cache, key(), chunk=4, now=1.7, busy=True)
    assert offer(cache, key(), chunk=5, now=1.8)
    await cache.pending_task
    await cache.formal(key(), result)
    assert not offer(cache, key(), chunk=6, now=2)


@pytest.mark.asyncio
async def test_changed_text_on_same_decode_is_not_new_evidence():
    cache = speculative.SpeculativeTranslation()
    offer(cache, key(), chunk=1, now=0)
    changed = key(source='新句子。')
    assert not offer(cache, changed, chunk=1, now=1)
    assert not offer(cache, changed, chunk=2, now=2)
    assert offer(cache, changed, chunk=3, now=3)
    await cache.pending_task


@pytest.mark.asyncio
async def test_generation_invalidation_discards_running_completion():
    cache = speculative.SpeculativeTranslation()
    started, release = asyncio.Event(), asyncio.Event()
    async def blocked():
        started.set()
        await release.wait()
        return 'previous stream'
    offer(cache, key(), blocked, chunk=1, now=0)
    offer(cache, key(), blocked, now=1)
    task = cache.pending_task
    await started.wait()
    cache.invalidate(key().generation)
    release.set()
    await task
    assert cache.counters['wasted'] == 1
    assert await cache.formal(key(), result) == 'May the Lord bless you.'


@pytest.mark.asyncio
async def test_queued_formal_preempts_not_started_different_speculation():
    cache = speculative.SpeculativeTranslation()
    async def forbidden():
        raise AssertionError('speculative request must yield to formal work')
    offer(cache, key(), forbidden, chunk=1, now=0)
    offer(cache, key(), forbidden, now=1)
    assert await cache.formal(key(revision=2), result) == 'May the Lord bless you.'
    assert cache.counters['hits'] == 0


@pytest.mark.asyncio
async def test_unkeyable_formal_request_never_joins_invalidated_preflight():
    cache = speculative.SpeculativeTranslation()
    started, release = asyncio.Event(), asyncio.Event()
    async def blocked():
        started.set()
        await release.wait()
        return 'wrong language'
    offer(cache, key(), blocked, chunk=1, now=0)
    offer(cache, key(), blocked, now=1)
    await started.wait()
    cache.invalidate()
    formal = asyncio.create_task(cache.formal(None, result))
    await asyncio.sleep(0)
    release.set()
    assert await formal == 'May the Lord bless you.'


@pytest.mark.asyncio
async def test_stale_completion_counted_once_after_repeated_invalidations():
    cache = speculative.SpeculativeTranslation()
    started, release = asyncio.Event(), asyncio.Event()
    async def blocked():
        started.set()
        await release.wait()
        return 'obsolete'
    offer(cache, key(), blocked, chunk=1, now=0)
    offer(cache, key(), blocked, now=1)
    task = cache.pending_task
    await started.wait()
    cache.invalidate()
    release.set()
    await task
    cache.invalidate()
    assert cache.counters['wasted'] == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('field,value', [('sampling_profile', 'default'), ('model', 'other-model'),
    ('max_new_tokens', 128), ('chat_url', 'http://other/v1/chat/completions')])
async def test_actual_translator_context_change_forces_fresh_computation(field, value):
    from voxbridge.cli.demo_streaming_ws import OpenAIAPITranslator, _speculative_translation_key
    translator = OpenAIAPITranslator('http://127.0.0.1:8876', 'hy-mt', sampling_profile='mac-verified', max_new_tokens=256)
    def context_key():
        return _speculative_translation_key(translator, '愿主赐福给你。', 'Chinese', 'English', 'zh2en', ('stream', 1), 1)
    cache = speculative.SpeculativeTranslation()
    original = context_key()
    offer(cache, original, chunk=1, now=0)
    offer(cache, original, now=1)
    await cache.pending_task
    setattr(translator, field, value)
    async def fresh(): return 'fresh context result'
    assert await cache.formal(context_key(), fresh) == 'fresh context result'


@pytest.mark.asyncio
async def test_cancelled_queued_formal_does_not_run_obsolete_inference():
    cache = speculative.SpeculativeTranslation()
    started, release = asyncio.Event(), asyncio.Event()
    outputs = []
    async def blocked():
        started.set()
        await release.wait()
        return 'active'
    async def obsolete():
        outputs.append('obsolete ran')
        return 'obsolete'
    first = asyncio.create_task(cache.formal(key(), blocked))
    await started.wait()
    queued = asyncio.create_task(cache.formal(key(revision=2), obsolete))
    await asyncio.sleep(0)
    await asyncio.sleep(0)
    queued.cancel()
    with pytest.raises(asyncio.CancelledError): await queued
    release.set()
    assert await first == 'active'
    await asyncio.sleep(0)
    assert outputs == []


def test_local_chat_template_is_part_of_exact_context():
    from types import SimpleNamespace
    from voxbridge.cli.demo_streaming_ws import LocalTranslator, _speculative_translation_key
    translator = LocalTranslator.__new__(LocalTranslator)
    translator.source_language, translator.target_language = 'Chinese', 'English'
    translator.model = object()
    translator.tokenizer = SimpleNamespace(chat_template='original chat template')
    def context_key():
        return _speculative_translation_key(translator, '愿主赐福给你。', 'Chinese', 'English', 'zh2en', ('stream', 1), 1)
    original = context_key()
    translator.tokenizer.chat_template = 'changed chat template'
    assert context_key() != original


@pytest.mark.asyncio
@pytest.mark.parametrize("already_completed", [False, True])
async def test_invalidated_running_result_claimed_by_formal_is_hit_not_waste(already_completed):
    cache = speculative.SpeculativeTranslation()
    started, release, claimed = asyncio.Event(), asyncio.Event(), asyncio.Event()
    traces = []
    async def blocked():
        started.set()
        await release.wait()
        return 'claimed translation'
    def trace(event, **fields): traces.append((event, fields))
    cache.offer(key(), blocked, observation=(1, 1), now=0, complete=True, trace=trace)
    cache.offer(key(), blocked, observation=(1, 2), now=1, complete=True, trace=trace)
    await started.wait()
    if already_completed:
        release.set()
        await cache.pending_task
    formal = asyncio.create_task(cache.formal(key(), result, trace=trace))
    # FIFO loop barrier: formal() captures its cache claim before this callback.
    asyncio.get_running_loop().call_soon(claimed.set)
    await claimed.wait()
    cache.invalidate()
    release.set()
    assert await formal == 'claimed translation'
    cache.invalidate()
    assert cache.counters['hits'] == 1
    assert cache.counters['wasted'] == 0
    assert not any(event == 'translation_speculative_wasted' for event, _ in traces)


@pytest.mark.asyncio
@pytest.mark.parametrize('cancel_at_completion', [False, True])
async def test_cancelled_formal_claim_preserves_exactly_one_real_waste(cancel_at_completion):
    cache = speculative.SpeculativeTranslation()
    started, release, claimed = asyncio.Event(), asyncio.Event(), asyncio.Event()
    traces = []
    async def blocked():
        started.set()
        await release.wait()
        return 'unused translation'
    def trace(event, **fields): traces.append((event, fields))
    cache.offer(key(), blocked, observation=(1, 1), now=0, complete=True, trace=trace)
    cache.offer(key(), blocked, observation=(1, 2), now=1, complete=True, trace=trace)
    speculative_task = cache.pending_task
    await started.wait()
    formal = asyncio.create_task(cache.formal(key(), result, trace=trace))
    asyncio.get_running_loop().call_soon(claimed.set)
    await claimed.wait()
    cache.invalidate()
    if cancel_at_completion:
        speculative_task.add_done_callback(lambda _: formal.cancel())
    else:
        formal.cancel()
        with pytest.raises(asyncio.CancelledError): await formal
    release.set()
    await speculative_task
    if cancel_at_completion:
        with pytest.raises(asyncio.CancelledError): await formal
    # Let all cancellation completion callbacks settle before inspecting counters.
    settled = asyncio.Event()
    asyncio.get_running_loop().call_soon(settled.set)
    await settled.wait()
    cache.invalidate()
    assert cache.counters['hits'] == 0
    assert cache.counters['wasted'] == 1
    assert sum(event == 'translation_speculative_wasted' for event, _ in traces) == 1
    assert [fields['pending'] for event, fields in traces if event == 'translation_speculative_wasted'] == [0]


@pytest.mark.asyncio
async def test_one_cancelled_claim_does_not_waste_another_claims_hit():
    cache = speculative.SpeculativeTranslation()
    started, release, claimed = asyncio.Event(), asyncio.Event(), asyncio.Event()
    async def blocked():
        started.set()
        await release.wait()
        return 'shared exact translation'
    offer(cache, key(), blocked, chunk=1, now=0)
    offer(cache, key(), blocked, now=1)
    await started.wait()
    first = asyncio.create_task(cache.formal(key(), result))
    second = asyncio.create_task(cache.formal(key(), result))
    asyncio.get_running_loop().call_soon(claimed.set)
    await claimed.wait()
    cache.invalidate()
    first.cancel()
    with pytest.raises(asyncio.CancelledError): await first
    release.set()
    assert await second == 'shared exact translation'
    cache.invalidate()
    assert cache.counters['hits'] == 1
    assert cache.counters['wasted'] == 0


@pytest.mark.asyncio
async def test_completed_unused_cache_invalidation_emits_one_waste():
    cache = speculative.SpeculativeTranslation()
    traces = []
    def trace(event, **fields): traces.append((event, fields))
    cache.offer(key(), result, observation=(1, 1), now=0, complete=True, trace=trace)
    cache.offer(key(), result, observation=(1, 2), now=1, complete=True, trace=trace)
    await cache.pending_task
    cache.invalidate()
    cache.invalidate()
    assert cache.counters['hits'] == 0
    assert cache.counters['wasted'] == 1
    assert sum(event == 'translation_speculative_wasted' for event, _ in traces) == 1
