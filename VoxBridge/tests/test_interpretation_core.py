"""Behavior at the reusable core boundary, without a web application."""
from dataclasses import FrozenInstanceError
import importlib.util
import pytest


def core_module(name):
    # A core consumer must be usable without constructing the CLI / web app.
    assert importlib.util.find_spec(name), f"missing reusable module: {name}"
    return __import__(name, fromlist=['*'])


def test_language_pair_drives_both_asr_and_speech_without_direction_fallback():
    catalog = core_module('voxbridge.languages')
    pair = catalog.translation_pair('en', 'zh')
    assert (pair.direction, pair.source.asr_label, pair.target.tts_label) == ('en2zh', 'English', 'Chinese')
    assert catalog.translation_pair('zh', 'en').direction == 'zh2en'
    with pytest.raises(ValueError):
        catalog.translation_pair('de', 'zh')
    with pytest.raises(ValueError):
        catalog.translation_pair('en', 'en')
    with pytest.raises((FrozenInstanceError, AttributeError)):
        pair.source = pair.target


@pytest.mark.asyncio
async def test_standalone_translation_service_retries_wrong_language_and_retains_name():
    from voxbridge.interpretation.contracts import TranslationRequest
    from voxbridge.translation.service import TranslationService

    class Backend:
        enforce_target_language_output = True
        def translate(self, text, source_language, target_language,
                      translation_direction, strict_target_language=False):
            assert (source_language, target_language, translation_direction) == ('English', 'Chinese', 'en2zh')
            if text == 'Welcome to PCCS.':
                return '欢迎来到 PCCS。' if strict_target_language else 'welcome to our church'
            return 'John van der Meer'

    events = []
    errors = []
    service = TranslationService(Backend(), trace=lambda event, **fields: events.append((event, fields)),
                                 on_error=errors.append)
    request = TranslationRequest('s1', 1, 'Welcome to PCCS.', 'English', 4, 1, 'English', 'Chinese', 'en2zh')
    assert await service.translate(request) == '欢迎来到 PCCS。'
    assert [event for event, _ in events] == ['translation_target_language_mismatch', 'translation_done']
    assert events[-1][1]['quality_retry_count'] == 1
    assert events[-1][1]['revision'] == 1
    name = request._replace(sentence_id='s2', source_text='John van der Meer')
    assert await service.translate(name) == 'John van der Meer'
    assert events[-1][1]['quality_retry_count'] == 0
    assert errors == []


@pytest.mark.parametrize(('source', 'rejected', 'spellings'), [
    ('他投靠在腓力斯，并住在史葛拉。', 'He took refuge there and lived in Sh格拉.', (('史葛拉', 'Shigela'),)),
    ('这是一个叫做桃溪的小镇。', 'This is a small town called 桃溪.', (('桃溪', 'Taoxi'),)),
    ('他在耶路撒冷住过。', 'He lived in the city of 耶路撒冷.', ()),
    ('他住在史葛拉或石格拉。', 'He might have lived in Sh格拉.', ()),
    ('专业同工共同服侍。', 'The pastor and 同工 served together.', ()),
])
def test_english_name_recovery_is_anchored_to_source_and_prioritizes_glossary(source, rejected, spellings):
    from voxbridge.translation.name_recovery import english_name_spellings

    assert english_name_spellings(source, rejected, 'English') == spellings


@pytest.mark.asyncio
@pytest.mark.parametrize(('source', 'rejected', 'good', 'hint', 'fallback'), [
    ('他投靠在腓力斯，并住在史葛拉。', 'He sought refuge with the Philistines and lived in Sh格拉.',
     'He sought refuge with the Philistines and lived in Shigela.', '史葛拉”请用拉丁字母写作 Shigela', True),
    ('他在耶路撒冷住过。', 'He lived in the city of 耶路撒冷.', 'He lived in the city of Jerusalem.',
     '耶路撒冷 翻译成 Jerusalem', False),
])
async def test_english_name_recovery_guides_existing_strict_retry_without_changing_source(
    monkeypatch, source, rejected, good, hint, fallback,
):
    import io
    import json
    from voxbridge.interpretation.contracts import TranslationRequest
    from voxbridge.translation.backends import OpenAIAPITranslator
    from voxbridge.translation.service import TranslationService

    prompts = []

    def respond(request, timeout):
        prompt = json.loads(request.data)['messages'][0]['content']
        prompts.append(prompt)
        text = good if len(prompts) == 2 and hint in prompt else rejected
        return io.BytesIO(json.dumps({'choices': [{'finish_reason': 'stop', 'message': {'content': text}}]}).encode())

    monkeypatch.setattr('urllib.request.urlopen', respond)
    translator = OpenAIAPITranslator('http://127.0.0.1:8876', 'hy-mt')
    request = TranslationRequest('source-1', 1, source, 'Chinese', 1, 1, 'Chinese', 'English', 'zh2en')
    assert await TranslationService(translator).translate(request) == good
    assert len(prompts) == 2 and all(prompt.endswith(source) for prompt in prompts)
    assert (hint in prompts[0]) is not fallback
    assert ('请用拉丁字母写作' in prompts[1]) is fallback


@pytest.mark.asyncio
async def test_service_failure_is_reported_and_cancellation_is_not_swallowed():
    import asyncio
    from voxbridge.interpretation.contracts import TranslationRequest
    from voxbridge.translation.service import TranslationService

    class Backend:
        def translate(self, text, **kwargs):
            raise ValueError('incomplete translation')
    errors = []
    service = TranslationService(Backend(), on_error=errors.append)
    request = TranslationRequest('s', 1, '你好。', 'Chinese', 1, 1, 'Chinese', 'English', 'zh2en')
    assert await service.translate(request) == ''
    assert errors == ['translate failed: incomplete translation']

    class CancelledBackend:
        def translate(self, text, **kwargs):
            raise asyncio.CancelledError()
    with pytest.raises(asyncio.CancelledError):
        await TranslationService(CancelledBackend()).translate(request)


def test_translation_runtime_isolates_pending_work_between_sessions():
    from voxbridge.interpretation.contracts import TranslationRequest, TranslationRuntime
    a, b = TranslationRuntime(), TranslationRuntime()
    request = TranslationRequest('s', 1, 'Hello.', 'English', 1, 1, 'English', 'Chinese', 'en2zh')
    a.queue.put_nowait(request)
    a.latest_by_sentence['s'] = (1, 1, 'Hello.', 'en2zh')
    assert b.queue.empty() and b.latest_by_sentence == {}
    assert a.queue.get_nowait().source_text == 'Hello.'
    with pytest.raises(AttributeError):
        request.target_language = 'English'


def test_speech_profile_preserves_whole_chinese_sentence_and_rejects_unready_language():
    policy = core_module('voxbridge.tts.policy')
    text = '如果我们彼此相爱，神就住在我们里面，他的爱也在我们里面得以完全。'
    assert policy.speech_policy('Chinese').split(text) == (text,)
    assert policy.speech_policy('English').split('Welcome to our gathering.') == ('Welcome to our gathering.',)
    with pytest.raises(ValueError):
        policy.speech_policy('German')


@pytest.mark.asyncio
@pytest.mark.parametrize('source,target,direction', [
    ('German', 'Arabic', 'de2ar'),
    ('English', 'Chinese', 'zh2en'),
    ('English', 'English', 'en2en'),
])
async def test_service_rejects_invalid_pair_before_backend_inference(source, target, direction):
    from voxbridge.interpretation.contracts import TranslationRequest
    from voxbridge.translation.service import TranslationService
    class Backend:
        calls = 0
        def translate(self, text, **kwargs):
            self.calls += 1
            return 'unchecked translation'
    backend = Backend()
    request = TranslationRequest('s', 1, 'Hello.', source, 1, 1, source, target, direction)
    with pytest.raises(ValueError):
        await TranslationService(backend).translate(request)
    assert backend.calls == 0


@pytest.mark.asyncio
@pytest.mark.parametrize('source,target,direction,text', [
    ('Chinese (Simplified)', 'American English', 'zh2en', '你好。'),
    ('American English', 'Chinese (Simplified)', 'en2zh', 'Hello.'),
])
async def test_configured_legacy_labels_keep_exact_backend_prompt_inputs(source, target, direction, text):
    from voxbridge.interpretation.contracts import TranslationRequest
    from voxbridge.translation.service import TranslationService

    class Backend:
        def translate(self, sentence, **kwargs):
            assert sentence == text
            assert kwargs == dict(source_language=source, target_language=target,
                                  translation_direction=direction)
            return 'translated'

    service = TranslationService(Backend(), zh_label='Chinese (Simplified)',
                                 en_label='American English')
    request = TranslationRequest('s', 1, text, source, 1, 1, source, target, direction)
    assert await service.translate(request) == 'translated'
