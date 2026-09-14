"""Direction changes must keep ASR, translation, and speech in agreement."""
import sys
from types import SimpleNamespace

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voxbridge.cli.demo_streaming_ws import (
    _build_translation_prompt, _create_app, _translation_needs_target_language_retry,
)
from voxbridge.tts.kokoro_onnx import KokoroOnnxSynthesizer
from test_demo_streaming_ws_protocol import _args, _FakeASR, _receive_until_type
from test_kokoro_tts import FakeFactory, make_config


@pytest.mark.parametrize('command', ['start', 'set_translation_direction'])
@pytest.mark.parametrize('first,second', [('zh2en', 'en2zh'), ('en2zh', 'zh2en')])
def test_native_direction_locked_until_finish(monkeypatch, command, first, second):
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'test-native-private-token')
    args = _args(); args.native_console = True
    languages = {'zh2en': ('Chinese', 'English'), 'en2zh': ('English', 'Chinese')}
    with TestClient(_create_app(args, _FakeASR()), client=('127.0.0.1', 12345)) as client:
        for direction in (first, second, first):
            with client.websocket_connect('/ws', headers={'X-VoxBridge-Control-Token': 'test-native-private-token'}) as ws:
                _receive_until_type(ws, 'ready')
                source, target = languages[direction]
                # Explicit direction wins even if an outdated client sends the wrong ASR language.
                ws.send_json({'type': 'start', 'translation_direction': direction, 'language': target})
                started = _receive_until_type(ws, 'started')
                assert started['language'] == started['translation_source_language'] == source
                assert started['translation_target_language'] == target
                assert client.get('/api/monitor/state').json()['session']['direction'] == direction
                other = second if direction == first else first
                ws.send_json({'type': command, 'translation_direction': other})
                rejected = ws.receive_json()
                assert rejected['type'] == 'error'
                assert 'Stop capture' in rejected['message']
                assert client.get('/api/monitor/state').json()['session']['direction'] == direction
                ws.send_json({'type': 'finish'})
                _receive_until_type(ws, 'final')


def test_chinese_church_prompt_is_faithful_without_imposing_esv():
    prompt = _build_translation_prompt('The teacher served with his fellow workers.', 'English', 'Chinese', 'en2zh')
    assert '通行的中文圣经' in prompt
    assert '不得补写、扩写、解释、纠正或用记忆中的经文替换原文' in prompt
    assert 'ESV' not in prompt
    assert '省略不承载语义' in prompt
    strict = _build_translation_prompt('Welcome to PCCS.', 'English', 'Chinese', 'en2zh', True)
    assert '专有名词或缩写可保留原文' in strict


@pytest.mark.parametrize('text,retry', [
    ('The pastor and fellow workers serve together.', True),
    ('welcome to our church', True),
    ('牧师和同工一起服侍。', False),
    ('欢迎来到 PCCS，我们今天介绍 OpenAI。', False),
    ('OpenAI', False), ('New York City', False), ('PCCS', False), ('2026/09/14', False),
    ('John van der Meer', False), ('Church of the Highlands', False),
])
def test_chinese_target_guard_allows_proper_names(text, retry):
    assert _translation_needs_target_language_retry(text, 'Chinese') is retry


def test_english_to_chinese_retries_untranslated_sentence():
    class EnglishASR(_FakeASR):
        def streaming_transcribe(self, wav, state):
            state.language = 'English'
            state.text = 'The pastor and fellow workers serve together. We welcome you to our church today.'
            return state

    class Translator:
        enforce_target_language_output = True
        def __init__(self): self.calls = []
        def translate(self, text, source_language=None, target_language=None,
                      translation_direction=None, strict_target_language=False):
            self.calls.append((source_language, target_language, translation_direction, strict_target_language))
            return '牧师和同工一起服侍。' if strict_target_language else 'The pastor serves together with his fellow workers.'

    translator = Translator()
    with TestClient(_create_app(_args(), EnglishASR(), translator=translator)).websocket_connect('/ws') as ws:
        _receive_until_type(ws, 'ready')
        ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
        _receive_until_type(ws, 'started')
        ws.send_bytes(np.array([0, 1000, -1000], dtype='<i2').tobytes())
        translated = _receive_until_type(ws, 'sentence_translation')
        assert translated['translation'] == '牧师和同工一起服侍。'
    assert all(call[:3] == ('English', 'Chinese', 'en2zh') for call in translator.calls)
    flags = [call[3] for call in translator.calls]
    assert flags.count(False) == flags.count(True) >= 1


def test_default_chinese_g2p_speaks_embedded_english_without_loading_english_model(monkeypatch, tmp_path):
    calls = []
    class G2P:
        def __init__(self, *, version, en_callable=None): self.english = en_callable
        def __call__(self, text):
            return '中文音素 ' + (self.english('OpenAI') if self.english else '❓'), None
    monkeypatch.setitem(sys.modules, 'misaki.zh', SimpleNamespace(ZHG2P=G2P))
    class Factory(FakeFactory):
        def __call__(self, **kwargs):
            model = super().__call__(**kwargs)
            def phonemize(text, lang):
                calls.append((text, lang))
                return 'oʊpən eɪ aɪ'
            model.tokenizer = SimpleNamespace(phonemize=phonemize)
            return model
    factory = Factory()
    synth = KokoroOnnxSynthesizer(config=make_config(tmp_path), kokoro_factory=factory)
    synth.synthesize('欢迎使用 OpenAI。', 'Chinese')
    assert calls == [('OpenAI', 'en-us')]
    assert factory.models[0].calls[0].text == '中文音素 oʊpən eɪ aɪ'
    assert factory.models[0].calls[0].voice == 'zf_001'
    assert len(factory.models) == 1


@pytest.mark.parametrize('name,expect_retry', [
    ('John van der Meer', False),
    ('Church of the Highlands', False),
    ('the church of the good shepherd', True),
])
def test_chinese_translation_does_not_discard_preserved_latin_name(name, expect_retry):
    class EnglishASR(_FakeASR):
        def streaming_transcribe(self, wav, state):
            state.language = 'English'
            state.text = f'{name}.'
            return state
        def finish_streaming_transcribe(self, state):
            return state
    class NameTranslator:
        enforce_target_language_output = True
        def __init__(self): self.calls = []
        def translate(self, text, source_language=None, target_language=None,
                      translation_direction=None, strict_target_language=False):
            self.calls.append(strict_target_language)
            return name
    translator = NameTranslator()
    args = _args(); args.idle_timeout_sec = 3
    with TestClient(_create_app(args, EnglishASR(), translator=translator)).websocket_connect('/ws') as ws:
        _receive_until_type(ws, 'ready')
        ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
        _receive_until_type(ws, 'started')
        ws.send_bytes(np.array([0, 1000, -1000], dtype='<i2').tobytes())
        # A standalone name may stay in the tentative tail until capture ends.
        ws.send_json({'type': 'finish'})
        assert _receive_until_type(ws, 'final')['translation'] == name
    assert translator.calls
    assert (True in translator.calls) is expect_retry
