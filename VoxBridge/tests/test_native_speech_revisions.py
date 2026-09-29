import asyncio
import threading
import time

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voxbridge.cli.demo_streaming_ws import _create_app
from voxbridge.tts.kokoro_onnx import SynthesizedAudio
from test_demo_streaming_ws_protocol import (
    _args, _FastRevisionASR, _FakeTokenizer, _FakeTranslator, _receive_until_type, _silent_wav_bytes,
    _FakeASR,
)
from test_tts_hls import FakeEncoder
from types import SimpleNamespace


@pytest.mark.parametrize('sentence', ['The sixth day.', 'The work is complete.', 'He said, “The work is complete.”'])
def test_english_period_finalizes_at_confirmed_silence_without_extra_text_idle(tmp_path, sentence):
    """An audible endpoint must reach final ASR before speech is committed."""
    import json
    from pathlib import Path
    class ASR(_FakeASR):
        def streaming_transcribe(self, wav, state):
            state.audio_accum = np.concatenate((state.audio_accum, wav))
            state.language, state.text = 'English', sentence
            return state
        def finish_streaming_transcribe(self, state):
            self.finish_calls += 1
            return state
    asr = ASR()
    asr.transcribe_text = sentence
    asr.transcribe_language = 'English'
    args = _args()
    args.segment_final_redecode = True
    args.vad_silence_sec = 0.8
    args.vad_force_cut_sec = 1.8
    args.vad_min_slice_sec = 0.5
    args.vad_min_active_sec = 0.2
    args.backend_cut_stable_sec = 10  # Endpoint punctuation must bypass this fallback.
    args.final_redecode_on_stop = False
    args.subtitle_trace_log = True
    args.subtitle_trace_log_file = str(tmp_path / 'endpoint.jsonl')
    with TestClient(_create_app(args, asr)).websocket_connect('/ws') as ws:
        ws.receive_json()
        ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
        _receive_until_type(ws, 'started')
        ws.send_bytes(np.full(6400, 20000, dtype='<i2').tobytes())
        _receive_until_type(ws, 'partial')
        time.sleep(.55)
        ws.send_json({'type': 'audio_silence', 'duration_ms': 900, 'capture_sample_index': 20800})
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            rows = [json.loads(line) for line in Path(args.subtitle_trace_log_file).read_text().splitlines()]
            if any(r.get('event') in {'segment_cut_deferred', 'segment_finalize_deferred', 'segment_finalize_done'} for r in rows):
                break
            time.sleep(.01)
        if not any(r.get('event') == 'segment_finalize_done' for r in rows):
            # Short English terminal hypotheses require the existing 1.8s
            # endpoint guard, rather than the unrelated text-idle timeout.
            ws.send_json({'type': 'audio_silence', 'duration_ms': 1000, 'capture_sample_index': 36800})
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                rows = [json.loads(line) for line in Path(args.subtitle_trace_log_file).read_text().splitlines()]
                if any(r.get('event') == 'segment_finalize_done' for r in rows):
                    break
                time.sleep(.01)
        assert any(r.get('event') == 'segment_finalize_done' for r in rows)
        assert asr.finish_calls >= 1
        assert len(asr.transcribe_calls) >= 1


def test_native_revision_replaces_queued_audio_and_preserves_sentence_order(monkeypatch, tmp_path):
    entered, unblock = threading.Event(), threading.Event()
    class ASR(_FastRevisionASR):
        def __init__(self):
            super().__init__()
            self.processor = SimpleNamespace(tokenizer=_FakeTokenizer())
        def streaming_transcribe(self, wav, state):
            state = super().streaming_transcribe(wav, state)
            state.chunk_id = self.calls
            return state
    class Synthesizer:
        def synthesize(self, text, language, **kwargs):
            return SynthesizedAudio(_silent_wav_bytes(), sample_rate=24000, duration_ms=250)
    class Encoder(FakeEncoder):
        async def append_pcm_committed(self, pcm, *, is_current, on_commit):
            if len(self.appended) == 1:
                entered.set()
                while not unblock.is_set():
                    await asyncio.sleep(.005)
            return await super().append_pcm_committed(pcm, is_current=is_current, on_commit=on_commit)
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'revision-test')
    args = _args()
    args.native_console = args.tts_native_pcm = args.tts_stream_chunks = True
    args.tts_hls_root_dir = str(tmp_path)
    args.tts_hls_encoder_factory = Encoder
    asr = ASR()
    app = _create_app(args, asr, translator=_FakeTranslator(), tts_synthesizer=Synthesizer())
    headers = {'X-VoxBridge-Control-Token': 'revision-test'}
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        client.get('/api/native/tts/native-revision-test/pcm?after=-1', headers=headers).raise_for_status()
        with client.websocket_connect('/ws', headers=headers) as ws:
            ws.receive_json()
            ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
            _receive_until_type(ws, 'started')
            frame = np.array([0, 1000, -1000], dtype='<i2').tobytes()
            try:
                for _ in range(2):
                    ws.send_bytes(frame)
                    _receive_until_type(ws, 'partial')
                assert entered.wait(3), 'second sentence never reached publication'
                ws.send_bytes(frame)
                _receive_until_type(ws, 'partial')
                unblock.set()

                ws.send_json({'type': 'finish', 'mode': 'stop'})
                _receive_until_type(ws, 'final', max_steps=100)
                client.portal.call(app.state.tts_hls.wait_idle)
                chunks = app.state.tts_hls.native_pcm.snapshot(0)['chunks']
                texts = [c['text'] for c in chunks]
                assert len(texts) == 3
                assert asr.s1 in texts[0]
                assert asr.s2_long in texts[1]
                assert asr.s3 in texts[2]
                assert [c['source_order'] for c in chunks] == [0, 1, 2]
                assert not any(':addition:' in c['sentence_id'] for c in chunks)
            finally:
                unblock.set()


@pytest.mark.parametrize('sentence,ready_after', [
    ('The weather is pleasant and warm today.', 2),
    ('The total cost is 15 dollars today.', 3),
    ('We should not leave this place yet.', 3),
    ("We don't need any. Any new regulations.", 3),
    ('The transfer is not authorized for this account.', 0),
])
def test_native_confirmation_under_segment_final_redecode(monkeypatch, tmp_path, sentence, ready_after):
    tail = 'The following sentence provides enough words for the rollback window.'
    class ASR(_FakeASR):
        def __init__(self):
            super().__init__()
            self.processor = SimpleNamespace(tokenizer=_FakeTokenizer())
            self.calls = 0
        def streaming_transcribe(self, wav, state):
            self.calls += 1
            state.chunk_id = self.calls
            state.language = 'English'
            state.text = tail if ready_after == 0 and self.calls >= 3 else sentence + ' ' + tail
            return state
        def finish_streaming_transcribe(self, state):
            state.language = 'English'
            state.text = sentence + ' ' + tail
            return state
    class Synthesizer:
        def synthesize(self, text, language, **kwargs):
            return SynthesizedAudio(_silent_wav_bytes(), sample_rate=24000, duration_ms=250)
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'confirmation-test')
    args = _args()
    args.native_console = args.tts_native_pcm = args.tts_stream_chunks = args.segment_final_redecode = True
    args.tts_hls_root_dir = str(tmp_path)
    args.tts_hls_encoder_factory = FakeEncoder
    app = _create_app(args, ASR(), translator=_FakeTranslator(), tts_synthesizer=Synthesizer())
    headers = {'X-VoxBridge-Control-Token': 'confirmation-test'}
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        client.get('/api/native/tts/native-confirmation-test/pcm?after=-1', headers=headers).raise_for_status()
        with client.websocket_connect('/ws', headers=headers) as ws:
            ws.receive_json()
            ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
            _receive_until_type(ws, 'started')
            frame = np.array([0, 1000, -1000], dtype='<i2').tobytes()
            for decode in range(1, (ready_after or 3) + 1):
                ws.send_bytes(frame)
                _receive_until_type(ws, 'partial')
                if not ready_after or decode < ready_after:
                    time.sleep(.05)
                    assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0
            deadline = time.monotonic() + 3
            while ready_after and app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0 and time.monotonic() < deadline:
                time.sleep(.01)
            assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == (1 if ready_after else 0)
            if 'Any new regulations.' in sentence:
                chunks = app.state.tts_hls.native_pcm.snapshot(0)['chunks']
                assert "We don't need any Any new regulations." in chunks[0]['text']
            ws.send_json({'type': 'finish', 'mode': 'stop'})
            _receive_until_type(ws, 'final', max_steps=100)
            client.portal.call(app.state.tts_hls.wait_idle)
            assert len(app.state.tts_hls.native_pcm.snapshot(0)['chunks']) == 2


def test_final_shared_pcm_still_notifies_compatibility_listeners_after_capture_stops(monkeypatch, tmp_path):
    from test_tts_hls import FakeSynthesizer, make_wav
    entered, unblock = threading.Event(), threading.Event()
    class Encoder(FakeEncoder):
        async def append_pcm_committed(self, pcm, *, is_current, on_commit):
            entered.set()
            while not unblock.is_set():
                await asyncio.sleep(.005)
            return await super().append_pcm_committed(pcm, is_current=is_current, on_commit=on_commit)
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'review-test-only')
    args = _args()
    args.native_console = args.tts_native_pcm = args.tts_stream_chunks = True
    args.tts_hls_encoder_factory = Encoder
    args.tts_hls_root_dir = str(tmp_path)
    app = _create_app(args, _FastRevisionASR(), translator=_FakeTranslator(),
                      tts_synthesizer=FakeSynthesizer(make_wav()))
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        subscription = client.portal.call(app.state.tts_broadcast.register, 'review-compat-listener')
        headers = {'X-VoxBridge-Control-Token': 'review-test-only'}
        client.get('/api/native/tts/review-listener/pcm?after=-1', headers=headers).raise_for_status()
        with client.websocket_connect('/ws', headers=headers) as ws:
            ws.receive_json()
            ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
            _receive_until_type(ws, 'started')
            try:
                for _ in range(2):
                    ws.send_bytes(np.array([0, 1000, -1000], dtype='<i2').tobytes())
                    _receive_until_type(ws, 'partial')
                assert entered.wait(2)
                ws.send_json({'type': 'finish', 'mode': 'stop'})
                _receive_until_type(ws, 'final', max_steps=100)
                client.portal.call(asyncio.sleep, .03)
                unblock.set()
                client.portal.call(app.state.tts_hls.wait_idle)
                chunks = app.state.tts_hls.native_pcm.snapshot(0)['chunks']
                print('Native PCM items:', len(chunks))
                print('Broadcast jobs:', app.state.tts_broadcast.job_count)
                assert len(chunks) == 3
                assert app.state.tts_broadcast.job_count == 3
                events = []
                while not subscription.queue.empty():
                    events.append(subscription.queue.get_nowait())
                jobs = [e for e in events if e['type'] == 'tts_job']
                print('Compatibility tts_job events:', len(jobs))
                assert len(jobs) == 3
            finally:
                unblock.set()


@pytest.mark.parametrize('repeat', [False, True])
def test_complete_comma_units_publish_early_and_all_final_words_reach_pcm(monkeypatch, tmp_path, repeat):
    """New early release must conserve the complete stream, including real repeats."""
    import re
    first = 'We have already completed the first stage of this project,'
    second = 'and we have already started the next stage of this project,'
    last = 'and we will explain every remaining detail at the next meeting.'
    full = ' '.join([first, *([first] if repeat else []), second, last])
    class ASR(_FakeASR):
        def __init__(self):
            super().__init__()
            self.processor = SimpleNamespace(tokenizer=_FakeTokenizer())
            self.transcribe_text, self.transcribe_language = full, 'English'
        def streaming_transcribe(self, wav, state):
            state.chunk_id = getattr(state, 'chunk_id', 0) + 1
            state.text, state.language = full, 'English'
            return state
        def finish_streaming_transcribe(self, state): return state
    class Synthesizer:
        def synthesize(self, text, language, **kwargs):
            return SynthesizedAudio(_silent_wav_bytes(), sample_rate=24000, duration_ms=250)
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'coverage-test')
    args = _args()
    args.native_console = args.tts_native_pcm = args.tts_stream_chunks = args.segment_final_redecode = True
    args.final_redecode_on_stop = False
    args.stable_clause_target_latin_words = 8
    args.tts_hls_root_dir = str(tmp_path)
    args.tts_hls_encoder_factory = FakeEncoder
    app = _create_app(args, ASR(), translator=_FakeTranslator(), tts_synthesizer=Synthesizer())
    headers = {'X-VoxBridge-Control-Token': 'coverage-test'}
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        client.get('/api/native/tts/native-coverage-test/pcm?after=-1', headers=headers).raise_for_status()
        with client.websocket_connect('/ws', headers=headers) as ws:
            ws.receive_json()
            ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
            _receive_until_type(ws, 'started')
            for _ in range(3):
                ws.send_bytes(np.array([0, 1000, -1000], dtype='<i2').tobytes())
                _receive_until_type(ws, 'partial')
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0:
                time.sleep(.01)
            assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] > 0, 'complete comma clause waited for finalization'
            ws.send_json({'type': 'finish', 'mode': 'stop'})
            _receive_until_type(ws, 'final', max_steps=100)
            client.portal.call(app.state.tts_hls.wait_idle)
            rows = app.state.monitor.snapshot()['rows']
            published = [p for r in rows for p in r.get('spoken', [])]
            expected_words = re.findall(r'\w+', full.lower())
            actual_words = re.findall(r'\w+', ' '.join(p['source'] for p in published).lower())
            assert actual_words == expected_words
            chunks = app.state.tts_hls.native_pcm.snapshot(0)['chunks']
            assert {c['sentence_id'] for c in chunks} == {p['sentence_id'] for p in published}
            for p in published:
                audio_text = ' '.join(c['text'] for c in chunks if c['sentence_id'] == p['sentence_id'])
                assert re.findall(r'\w+', audio_text) == re.findall(r'\w+', p['text'])
            assert app.state.speech_diagnostics() == []


def test_native_carried_complement_and_last_sentence_both_reach_pcm(monkeypatch, tmp_path):
    class ASR(_FakeASR):
        active_segments = 0
        def __init__(self):
            super().__init__()
            self.processor = SimpleNamespace(tokenizer=_FakeTokenizer())
        def streaming_transcribe(self, wav, state):
            if not hasattr(state, 'segment'):
                self.active_segments += 1
                state.segment = self.active_segments
            state.language = 'English'
            state.chunk_id = getattr(state, 'chunk_id', 0) + 1
            state.text = ("We don't need any." if state.segment == 1 else
                          'Any new regulations. The current laws already cover all of those problems.')
            return state
        def finish_streaming_transcribe(self, state): return state
    class Synthesizer:
        def synthesize(self, text, language, **kwargs):
            return SynthesizedAudio(_silent_wav_bytes(), sample_rate=24000, duration_ms=250)
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'carry-test')
    args = _args()
    args.native_console = args.tts_native_pcm = args.tts_stream_chunks = True
    args.segment_hard_cut_sec, args.segment_overlap_sec = 1.0, 0.0
    args.final_redecode_on_stop = False
    args.early_translation_stable_sec, args.early_translation_stable_hits = 0, 2
    args.tts_hls_root_dir = str(tmp_path)
    args.tts_hls_encoder_factory = FakeEncoder
    app = _create_app(args, ASR(), translator=_FakeTranslator(), tts_synthesizer=Synthesizer())
    headers = {'X-VoxBridge-Control-Token': 'carry-test'}
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        client.get('/api/native/tts/native-carry-test/pcm?after=-1', headers=headers).raise_for_status()
        with client.websocket_connect('/ws', headers=headers) as ws:
            ws.receive_json()
            ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
            _receive_until_type(ws, 'started')
            frame = np.array([0, 1200, -1200] * 2400, dtype='<i2').tobytes()
            ws.send_bytes(frame)
            _receive_until_type(ws, 'partial')
            time.sleep(1.1)
            for _ in range(6):
                ws.send_bytes(frame)
                _receive_until_type(ws, 'partial')
            ws.send_json({'type': 'finish', 'mode': 'stop'})
            _receive_until_type(ws, 'final', max_steps=100)
            client.portal.call(app.state.tts_hls.wait_idle)
            chunks = app.state.tts_hls.native_pcm.snapshot(0)['chunks']
            speech = ' '.join(c['text'] for c in chunks)
            assert speech.count("We don't need any Any new regulations.") == 1
            assert speech.count('The current laws already cover all of those problems.') == 1
            assert app.state.speech_diagnostics() == []


@pytest.mark.parametrize('following_row,revised_extension', [(False, False), (True, False), (False, True)])
def test_early_pcm_late_extension_survives_final_drain(monkeypatch, tmp_path, following_row, revised_extension):
    """A later suffix must reach PCM even after its parent's audio is immutable."""
    first = 'We have already completed the first stage of this project'
    extra = 'and we have checked every remaining detail'
    revised = 'and we have carefully checked every remaining detail and signed the final report'
    tail = 'The next report will provide enough context for everyone to understand.'
    class ASR(_FakeASR):
        phase = 0
        def __init__(self):
            super().__init__()
            self.processor = SimpleNamespace(tokenizer=_FakeTokenizer())
        def streaming_transcribe(self, wav, state):
            state.chunk_id = getattr(state, 'chunk_id', 0) + 1
            state.language = 'English'
            state.text = first + (', ' + extra if self.phase else '') + '. ' + tail
            if self.phase == 2 and revised_extension:
                state.text = first + ', ' + revised + '. ' + tail
            if self.phase == 2 and following_row:
                state.text = first + '. ' + extra + '. ' + tail
            return state
        def finish_streaming_transcribe(self, state): return state
    class Synthesizer:
        def synthesize(self, text, language, **kwargs):
            return SynthesizedAudio(_silent_wav_bytes(), sample_rate=24000, duration_ms=250)
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'extension-test')
    args = _args()
    args.subtitle_trace_log = True
    args.subtitle_trace_log_file = str(tmp_path / 'extension.jsonl')
    args.native_console = args.tts_native_pcm = args.tts_stream_chunks = args.segment_final_redecode = True
    args.final_redecode_on_stop = False
    args.tts_hls_root_dir = str(tmp_path)
    args.tts_hls_encoder_factory = FakeEncoder
    asr = ASR()
    app = _create_app(args, asr, translator=_FakeTranslator(), tts_synthesizer=Synthesizer())
    headers = {'X-VoxBridge-Control-Token': 'extension-test'}
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        client.get('/api/native/tts/native-extension-test/pcm?after=-1', headers=headers).raise_for_status()
        with client.websocket_connect('/ws', headers=headers) as ws:
            ws.receive_json()
            ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
            _receive_until_type(ws, 'started')
            frame = np.array([0, 1000, -1000], dtype='<i2').tobytes()
            for _ in range(3):
                ws.send_bytes(frame)
                _receive_until_type(ws, 'partial')
            deadline = time.monotonic() + 2
            while app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0 and time.monotonic() < deadline:
                time.sleep(.01)
            assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 1
            for phase in (1, 2):
                asr.phase = phase
                for _ in range(3):
                    ws.send_bytes(frame)
                    _receive_until_type(ws, 'partial')
                time.sleep(.03)
            ws.send_json({'type': 'finish', 'mode': 'stop'})
            _receive_until_type(ws, 'final', max_steps=100)
            client.portal.call(app.state.tts_hls.wait_idle)
            chunks = app.state.tts_hls.native_pcm.snapshot(0)['chunks']
            speech = ' '.join(c['text'] for c in chunks)
            assert speech.count(first) == 1
            assert speech.count(revised if revised_extension else extra) == 1, app.state.monitor.snapshot()['rows']
            if revised_extension:
                assert extra not in speech
            assert speech.count(tail) == 1
            assert app.state.speech_diagnostics() == []
