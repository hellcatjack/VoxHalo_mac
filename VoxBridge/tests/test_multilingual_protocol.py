"""Every advertised language pair must survive the native session boundary."""
import pytest
from fastapi.testclient import TestClient
from voxbridge.cli.demo_streaming_ws import _create_app, _compact_asr_compare_text
from voxbridge.languages import LANGUAGES, translation_pair
from voxbridge.streaming.sentence_rules import _join_segments
from test_demo_streaming_ws_protocol import _args, _FakeASR, _receive_until_type

PAIRS = [translation_pair(a.code, b.code) for a in LANGUAGES for b in LANGUAGES if a != b]

@pytest.mark.parametrize('pair', PAIRS, ids=lambda p: p.direction)
def test_native_starts_every_pair(monkeypatch, pair):
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'multilingual-test-token')
    args = _args(); args.native_console = True
    with TestClient(_create_app(args, _FakeASR()), client=('127.0.0.1', 12345)) as client:
        with client.websocket_connect('/ws', headers={'X-VoxBridge-Control-Token': 'multilingual-test-token'}) as ws:
            _receive_until_type(ws, 'ready')
            ws.send_json({'type': 'start', 'translation_direction': pair.direction, 'language': pair.target.asr_label})
            event = _receive_until_type(ws, 'started')
            assert event['translation_direction'] == pair.direction
            assert event['language'] == event['translation_source_language'] == pair.source.asr_label
            assert event['translation_target_language'] == pair.target.tts_label
            state = client.get('/api/monitor/state').json()['session']
            assert state['source_name'] == pair.source.name
            assert state['target_name'] == pair.target.name
            ws.send_json({'type': 'finish'})
            _receive_until_type(ws, 'final')

@pytest.mark.parametrize('command', ['start', 'set_translation_direction'])
@pytest.mark.parametrize('direction', ['de2en', 'ja2ja', 'nonsense'])
def test_bad_pair_rejected_without_start(command, direction):
    with TestClient(_create_app(_args(), _FakeASR())) as client:
        with client.websocket_connect('/ws') as ws:
            _receive_until_type(ws, 'ready')
            ws.send_json({'type': command, 'translation_direction': direction})
            event = ws.receive_json()
            assert event['type'] == 'error'
            assert client.get('/api/monitor/state').json()['session']['status'] != 'running'

def test_capability_catalog_exposes_exactly_56_pairs():
    with TestClient(_create_app(_args(), _FakeASR())) as client:
        response = client.get('/api/languages')
        assert response.status_code == 200
        data = response.json()
        assert len(data['languages']) == 8
        assert set(data['directions']) == {p.direction for p in PAIRS}

def test_hindi_vowels_are_preserved_in_revision_comparison():
    assert _compact_asr_compare_text('दिन।') != _compact_asr_compare_text('दीन।')
    assert _compact_asr_compare_text('नमस्ते!') == 'नमस्ते'

def test_multilingual_join_preserves_word_boundaries():
    assert _join_segments(['नमस्ते', 'दुनिया']) == 'नमस्ते दुनिया'
    assert _join_segments(['café', 'délicieux']) == 'café délicieux'
    assert _join_segments(['今日は', '晴れ']) == '今日は晴れ'

@pytest.mark.parametrize('source,target,sentence,tail', [
    ('fr','es','Bonjour à tous.','La réunion commence maintenant'),
    ('hi','ja','यह पहला वाक्य है।','अब हम आगे बढ़ेंगे'),
    ('ja','hi','今日は晴れです。','これから会議を始めます'),
])
def test_new_source_complete_sentence_does_not_use_english_fragment_hold(source,target,sentence,tail):
    import numpy as np
    from voxbridge.languages import language_profile
    class ASR(_FakeASR):
        def streaming_transcribe(self,wav,state):
            state.language=language_profile(source).asr_label
            state.text=sentence+tail
            return state
        def finish_streaming_transcribe(self,state): return state
    args=_args();args.early_translation_stable_sec=0;args.early_translation_stable_hits=1
    args.subtitle_trace_log=False
    events=[]
    with TestClient(_create_app(args,ASR())).websocket_connect('/ws') as ws:
        _receive_until_type(ws,'ready')
        ws.send_json({'type':'start','translation_direction':source+'2'+target})
        _receive_until_type(ws,'started')
        for _ in range(4):
            ws.send_bytes(np.array([0,1000,-1000],dtype='<i2').tobytes())
            while True:
                event=ws.receive_json();events.append(event)
                if event['type']=='partial':break
        assert sentence in [e['text'] for e in events if e['type']=='sentence_committed']


def test_missing_target_voice_fails_before_asr_starts():
    from voxbridge.tts.kokoro_onnx import TTSConfigurationError
    class MissingVoice:
        def validate_language(self,language):
            raise TTSConfigurationError('Japanese dictionary missing')
    # Preflight uses an ordinary fake TTS instance's full service interface.
    from test_demo_streaming_ws_protocol import _FakeTTSSynthesizer, _FakeTranslator
    synth=_FakeTTSSynthesizer()
    synth.validate_language=MissingVoice().validate_language
    asr=_FakeASR()
    with TestClient(_create_app(_args(),asr,translator=_FakeTranslator(),tts_synthesizer=synth)) as client:
        with client.websocket_connect('/ws') as ws:
            _receive_until_type(ws,'ready')
            previous=len(asr.init_calls)
            ws.send_json({'type':'start','translation_direction':'en2ja'})
            event=ws.receive_json()
            assert event['type']=='error' and 'dictionary missing' in event['message']
            assert len(asr.init_calls)==previous
