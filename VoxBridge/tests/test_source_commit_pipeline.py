"""Regression playback of source-boundary failures observed on 2026-09-28."""
import time

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voxbridge.cli.demo_streaming_ws import _create_app
from test_demo_streaming_ws_protocol import (
    _FakeASR, _FakeTranslator, _args, _receive_until_type, _collect_through_final,
)


def test_physical_window_does_not_translate_open_quantifier_as_a_complete_sentence():
    class ASR(_FakeASR):
        active_segments = 0

        def streaming_transcribe(self, wav, state):
            if not hasattr(state, 'segment'):
                self.active_segments += 1
                state.segment = self.active_segments
            state.language = 'English'
            state.chunk_id = getattr(state, 'chunk_id', 0) + 1
            state.text = ("We don't need any." if state.segment == 1 else
                          'Any new regulations. The current laws already cover all of those problems.')
            return state

        def finish_streaming_transcribe(self, state):
            return state

    args = _args()
    args.segment_hard_cut_sec = 1.0
    args.segment_overlap_sec = 0.0
    args.final_redecode_on_stop = False
    args.early_translation_stable_sec = 0
    args.early_translation_stable_hits = 2
    translator = _FakeTranslator()
    with TestClient(_create_app(args, ASR(), translator=translator)).websocket_connect('/ws') as ws:
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
        _collect_through_final(ws)
    sources = [call[0] for call in translator.calls]
    assert "We don't need any." not in sources
    assert 'Any new regulations.' not in sources
    assert any("We don't need any" in text and 'new regulations.' in text for text in sources)


def test_soft_boundary_does_not_drop_confidence_object():
    sentence = ("I am empathetic to the enormous challenges that they are dealing with, "
                "and I also have a lot of confidence in in, the capabilities of their teams.")
    class ASR(_FakeASR):
        def streaming_transcribe(self, wav, state):
            state.language, state.text = 'English', sentence
            state.chunk_id = getattr(state, 'chunk_id', 0) + 1
            return state
        def finish_streaming_transcribe(self, state):
            return state
    args = _args()
    args.final_redecode_on_stop = False
    translator = _FakeTranslator()
    with TestClient(_create_app(args, ASR(), translator=translator)).websocket_connect('/ws') as ws:
        ws.receive_json()
        ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
        _receive_until_type(ws, 'started')
        for _ in range(3):
            ws.send_bytes(np.array([0, 1200, -1200], dtype='<i2').tobytes())
            _receive_until_type(ws, 'partial')
        ws.send_json({'type': 'finish', 'mode': 'stop'})
        _collect_through_final(ws)
    sources = [call[0] for call in translator.calls]
    assert sentence in sources
    assert not any(text.endswith('confidence in in,') for text in sources)


@pytest.mark.parametrize('repeats', [1, 2])
def test_revision_resegmentation_does_not_retranslate_the_same_question(repeats):
    first = 'There are already enough laws in place.'
    grown = 'There are already enough laws in place, why add more laws?'
    question = 'Why add more laws?'
    tail = 'The next sentence provides enough context for the system to continue.'
    class ASR(_FakeASR):
        calls = 0
        def streaming_transcribe(self, wav, state):
            self.calls += 1
            state.language, state.chunk_id = 'English', self.calls
            prefix = first if self.calls <= 2 else grown if self.calls <= 5 else first + ' ' + ' '.join([question] * repeats)
            state.text = prefix + ' ' + tail
            return state
        def finish_streaming_transcribe(self, state):
            return state
    args = _args()
    args.final_redecode_on_stop = False
    args.early_translation_stable_sec = 0
    args.early_translation_stable_hits = 2
    translator = _FakeTranslator()
    with TestClient(_create_app(args, ASR(), translator=translator)).websocket_connect('/ws') as ws:
        ws.receive_json()
        ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
        _receive_until_type(ws, 'started')
        for _ in range(8):
            ws.send_bytes(np.array([0, 1200, -1200], dtype='<i2').tobytes())
            _receive_until_type(ws, 'partial')
            time.sleep(.02)
        ws.send_json({'type': 'finish', 'mode': 'stop'})
        _collect_through_final(ws)
    sources = [call[0] for call in translator.calls]
    assert grown in sources
    assert sources.count(question) == repeats - 1
