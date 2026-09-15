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
