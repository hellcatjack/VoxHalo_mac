"""Qwen-like hard-cut carry playback through actual native PCM publication."""
import json
import re
import time

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voxbridge.cli.demo_streaming_ws import _create_app
from voxbridge.tts.kokoro_onnx import SynthesizedAudio
from test_demo_streaming_ws_protocol import (
    _args, _FakeASR, _FakeTranslator, _receive_until_type, _silent_wav_bytes,
)
from test_tts_hls import FakeEncoder


def _words(text):
    return re.findall(r"[a-z]+(?:['’][a-z]+)?", text.lower())


@pytest.mark.parametrize('fresh_repeats', [1, 2])
@pytest.mark.parametrize('fresh_callbacks', [3, 5])
def test_hard_cut_discourse_carry_keeps_boundary_and_all_words_until_pcm(
    monkeypatch, tmp_path, fresh_repeats, fresh_callbacks,
):
    fragment = 'Yeah Well, first of all.'
    first = 'First of all, as you know, we are going through a major change.'
    last = 'The next sentence provides enough context for us to continue.'
    fresh = ' '.join([*([first] * fresh_repeats), last])
    expected = fragment + ' ' + fresh

    class ASR(_FakeASR):
        active_segments = 0

        def init_streaming_state(self, **kwargs):
            state = super().init_streaming_state(**kwargs)
            state.calls = 0
            state.chunk_id = 0
            return state

        def streaming_transcribe(self, wav, state):
            if not hasattr(state, 'segment'):
                self.active_segments += 1
                state.segment = self.active_segments
            state.audio_accum = np.concatenate((state.audio_accum, wav))
            state.calls += 1
            state.language = 'English'
            # Qwen can deliver several buffered callbacks for one real decode.
            state.chunk_id = (1 if state.segment == 1 else
                              [1, 1, 1, 2, 3, 4, 5, 6][min(state.calls - 1, 7)])
            state.text = fragment if state.segment == 1 else fresh
            return state

        def finish_streaming_transcribe(self, state):
            self.finish_calls += 1
            return state

    class Synthesizer:
        def synthesize(self, text, language, **kwargs):
            return SynthesizedAudio(_silent_wav_bytes(), sample_rate=24000, duration_ms=250)

    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'discourse-carry-test')
    args = _args()
    args.native_console = args.tts_native_pcm = args.tts_stream_chunks = True
    args.segment_final_redecode = True
    args.segment_hard_cut_sec, args.segment_overlap_sec = 1.0, 0.0
    args.final_redecode_on_stop = False
    args.early_translation_stable_sec = 0
    args.early_translation_short_stable_sec = 1.8
    args.early_translation_stable_hits = args.early_translation_short_stable_hits = 2
    args.subtitle_trace_log = True
    args.subtitle_trace_log_partial_every = 1
    args.subtitle_trace_log_file = str(tmp_path / 'discourse.jsonl')
    args.tts_hls_root_dir = str(tmp_path / 'hls')
    args.tts_hls_encoder_factory = FakeEncoder
    asr, translator = ASR(), _FakeTranslator()
    app = _create_app(args, asr, translator=translator, tts_synthesizer=Synthesizer())
    headers = {'X-VoxBridge-Control-Token': 'discourse-carry-test'}
    events = []

    def partial(ws):
        for _ in range(100):
            event = ws.receive_json()
            events.append(event)
            if event.get('type') == 'partial':
                return event
        pytest.fail('did not receive a partial event')

    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        client.get('/api/native/tts/native-discourse-test/pcm?after=-1',
                   headers=headers).raise_for_status()
        with client.websocket_connect('/ws', headers=headers) as ws:
            ws.receive_json()
            ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
            _receive_until_type(ws, 'started')
            initial_states = len(asr.init_calls)
            frame = np.array([0, 1200, -1200] * 2400, dtype='<i2').tobytes()
            ws.send_bytes(frame)
            partial(ws)
            time.sleep(1.1)
            # The idle supervisor hard-cuts segment 1 and carries its suffix.
            deadline = time.monotonic() + 2
            while len(asr.init_calls) == initial_states and time.monotonic() < deadline:
                time.sleep(.01)
            assert len(asr.init_calls) == initial_states + 1
            assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0

            ws.send_bytes(frame)
            partial(ws)
            assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0
            for call in range(2, fresh_callbacks + 1):
                ws.send_bytes(frame)
                partial(ws)
                time.sleep(.04)
                if call <= 4:
                    # Same decoder key never becomes another evidence hit;
                    # capitalization also retains the existing 3-hit safeguard.
                    assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0
            if fresh_callbacks == 5:
                deadline = time.monotonic() + .5
                while app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0 and time.monotonic() < deadline:
                    time.sleep(.01)
                assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] > 0, (
                    'assembled carry waited for another segment seal despite real fresh decode agreement'
                )
            else:
                assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0
            assert asr.finish_calls == 1, 'first PCM came only after a second hard-cut seal'
            rows_before_finish = app.state.monitor.snapshot()['rows']
            assert not any(row['source'] == fragment for row in rows_before_finish)
            assert not any(call[0] == fragment for call in translator.calls)

            ws.send_json({'type': 'finish', 'mode': 'stop'})
            _receive_until_type(ws, 'final', max_steps=100)
            client.portal.call(app.state.tts_hls.wait_idle)
            rows = app.state.monitor.snapshot()['rows']
            spoken = [item for row in rows for item in row.get('spoken', [])]
            assert _words(' '.join(item['source'] for item in spoken)) == _words(expected)
            chunks = app.state.tts_hls.native_pcm.snapshot(0)['chunks']
            assert {chunk['sentence_id'] for chunk in chunks} == {item['sentence_id'] for item in spoken}
            for item in spoken:
                audio_text = ' '.join(chunk['text'] for chunk in chunks
                                      if chunk['sentence_id'] == item['sentence_id'])
                assert _words(audio_text) == _words(item['text'])
            assert app.state.speech_diagnostics() == []

    trace = [json.loads(line) for line in (tmp_path / 'discourse.jsonl').read_text().splitlines()]
    assert any(row.get('event') == 'carried_discourse_assembled' for row in trace)
    assembly = [row for row in trace if row.get('event') == 'carried_discourse_assembled']
    assert len(assembly) >= 3, 'the assembled boundary must persist across decoder callbacks'
    waits = [row for row in trace if row.get('event') == 'tts_confirmation_wait']
    assert any(row.get('decode_hits') == 1 for row in waits)
    if fresh_callbacks == 5:
        assert any(row.get('decode_hits') == 2 for row in waits)
    else:
        assert not any(row.get('decode_hits', 0) > 1 for row in waits)
