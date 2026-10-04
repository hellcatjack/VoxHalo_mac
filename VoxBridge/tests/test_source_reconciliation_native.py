"""Native PCM coverage through live decoder many-to-one resegmentation."""
import asyncio
import re
import threading
import time

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voxbridge.cli.demo_streaming_ws import _create_app
from voxbridge.tts.kokoro_onnx import SynthesizedAudio
from test_demo_streaming_ws_protocol import (
    _args, _FakeASR, _FakeTranslator, _collect_through_final,
    _receive_until_type, _silent_wav_bytes,
)
from test_tts_hls import FakeEncoder


# Actual source wording in the 2026-10-03 native trace, before and after row 28
# absorbed row 29. Only punctuation changes, so all occurrence tokens survive.
FIRST = 'You access a website, it downloads application.'
SECOND = "Maybe it's Java application."
MERGED = "You access a website, it downloads application, maybe it's Java application."
FOLLOWING = 'The application still has to stay inside a carefully secured environment.'


def _wait_until(predicate, message, *, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.005)
    pytest.fail(message)


def _decode(ws, frame, events):
    ws.send_bytes(frame)
    while True:
        event = ws.receive_json()
        events.append(event)
        if event.get('type') == 'partial':
            return


@pytest.mark.parametrize('blocked_stage', ['synthesis', 'append', 'translation'])
@pytest.mark.parametrize('real_repeat,split_again,number_correction', [
    (False, False, False), (True, False, False), (False, True, False), (False, False, True),
])
def test_native_merge_retires_absorbed_source_before_first_pcm_and_final_seal(
        monkeypatch, tmp_path, blocked_stage, real_repeat, split_again, number_correction):
    """Already translated rows and obsolete in-flight audio must not reappear."""
    entered, unblock = threading.Event(), threading.Event()
    second = 'The receipt totals 15 USD.' if number_correction else SECOND
    merged = (FIRST[:-1] + ', ' + second[0].lower() + second[1:]) if number_correction else MERGED
    corrected = merged.replace('15 USD.', '50 USD for the entire year.')

    class ASR(_FakeASR):
        phase = 0

        def streaming_transcribe(self, wav, state):
            # Every invocation models a distinct decoder result, not a repeated
            # buffered callback counted as another speech-confirmation vote.
            state.chunk_id = getattr(state, 'chunk_id', 0) + 1
            state.language = 'English'
            source = (' '.join([FIRST, second]) if self.phase in {0, 2} else
                      corrected if self.phase == 3 else
                      ' '.join([merged, *([second] if real_repeat else [])]))
            state.text = source + ' ' + FOLLOWING
            return state

        def finish_streaming_transcribe(self, state):
            self.finish_calls += 1
            return state

    class Synthesizer:
        def synthesize(self, text, language, **kwargs):
            if blocked_stage in {'synthesis', 'translation'} and text.endswith(FIRST):
                entered.set()
                if not unblock.wait(10):
                    raise TimeoutError('test did not release obsolete source synthesis')
            return SynthesizedAudio(_silent_wav_bytes(), sample_rate=24000, duration_ms=250)

    class Translator(_FakeTranslator):
        child_entered = threading.Event()

        def translate(self, text, source_language=None, target_language=None):
            if blocked_stage == 'translation' and text == second:
                self.child_entered.set()
                if not unblock.wait(10):
                    raise TimeoutError('test did not release obsolete child translation')
            return super().translate(text, source_language, target_language)

    class Encoder(FakeEncoder):
        blocked = False

        async def append_pcm_committed(self, pcm, *, is_current, on_commit):
            if blocked_stage == 'append' and not self.blocked:
                self.blocked = True
                entered.set()
                while not unblock.is_set():
                    await asyncio.sleep(.005)
            # This rechecks the real shared publisher guard after the race.
            return await super().append_pcm_committed(pcm, is_current=is_current, on_commit=on_commit)

    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'source-merge-test')
    args = _args()
    args.native_console = args.tts_native_pcm = args.tts_stream_chunks = True
    args.segment_final_redecode = True
    args.final_redecode_on_stop = False
    args.early_translation_stable_sec = 0
    args.early_translation_stable_hits = 2
    args.stable_clause_target_latin_words = 16
    args.segment_hard_cut_sec = args.backend_cut_stable_sec = 120
    args.tts_hls_root_dir = str(tmp_path / blocked_stage)
    args.tts_hls_encoder_factory = Encoder
    asr, translator = ASR(), Translator()
    app = _create_app(args, asr, translator=translator, tts_synthesizer=Synthesizer())
    headers = {'X-VoxBridge-Control-Token': 'source-merge-test'}
    events = []
    with TestClient(app, client=('127.0.0.1', 1234)) as client:
        client.get('/api/native/tts/native-source-merge/pcm?after=-1', headers=headers).raise_for_status()
        with client.websocket_connect('/ws', headers=headers) as ws:
            ws.receive_json()
            ws.send_json({'type': 'start', 'translation_direction': 'en2zh'})
            _receive_until_type(ws, 'started')
            frame = np.array([0, 1000, -1000], dtype='<i2').tobytes()
            try:
                for _ in range(2):
                    _decode(ws, frame, events)
                _wait_until(lambda: entered.is_set(), 'old parent never entered the guarded audio stage')
                _wait_until(lambda: all(any(r['source'] == text and (
                                               r.get('translation') or blocked_stage == 'translation' and text == second)
                                           for r in app.state.monitor.snapshot()['rows'])
                                       for text in (FIRST, second)),
                            'both originals must be registered with completed or deliberately blocked translations')
                if blocked_stage == 'translation':
                    _wait_until(lambda: translator.child_entered.is_set(), 'old child MT did not enter its race')
                original = {r['source']: r for r in app.state.monitor.snapshot()['rows']
                            if r['source'] in (FIRST, second)}
                assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0
                parent_id, child_id = original[FIRST]['id'], original[second]['id']
                asr.phase = 1
                for _ in range(3):
                    _decode(ws, frame, events)
                _wait_until(lambda: any(r['id'] == parent_id and r['source'] == merged
                                        and r['revision'] == 2
                                        for r in app.state.monitor.snapshot()['rows']),
                            'merged source must keep the original parent identity with revision 2')
                if split_again:
                    # A subsequent decode splits the replacement back into the
                    # old FIRST and SECOND. Retiring SECOND must not let the
                    # parent contract to FIRST and silently drop imported words.
                    asr.phase = 2
                    for _ in range(3):
                        _decode(ws, frame, events)
                    retained = next(r for r in app.state.monitor.snapshot()['rows'] if r['id'] == parent_id)
                    assert retained['source'] == merged
                    assert retained['revision'] == 2
                    assert not any(r['id'] == child_id for r in app.state.monitor.snapshot()['rows'])
                if number_correction:
                    # The imported child keeps its first/last occurrences,
                    # while a later real decode corrects an interior number and
                    # completes its context. Coverage must not freeze old 15.
                    asr.phase = 3
                    for _ in range(3):
                        _decode(ws, frame, events)
                    _wait_until(lambda: any(r['id'] == parent_id and r['source'] == corrected
                                            and r['revision'] == 3
                                            for r in app.state.monitor.snapshot()['rows']),
                                'an interior numeric correction must replace the unpublished merged revision')
                assert app.state.tts_hls.native_pcm.snapshot(-1)['cursor'] == 0
                unblock.set()
                ws.send_json({'type': 'finish', 'mode': 'stop'})
                events.extend(_collect_through_final(ws))
                client.portal.call(app.state.tts_hls.wait_idle)
                chunks = app.state.tts_hls.native_pcm.snapshot(0)['chunks']
                # With a real repeated child, ordered alignment conservatively
                # retains its identity at the later occurrence (the longest
                # unchanged child+following block). A merge is not proven then;
                # preserving that child must still conserve the complete speech.
                assert [chunk['source_order'] for chunk in chunks] == ([0, 1, 2] if real_repeat else [0, 2]), {
                    'chunks': [(c['source_order'], c['sentence_id'], c['revision'], c['text']) for c in chunks],
                    'rows': app.state.monitor.snapshot()['rows'],
                    'events': [e for e in events if e.get('type') in {
                        'sentence_updated', 'sentence_committed', 'sentence_superseded'}],
                }
                assert chunks[0]['sentence_id'] == parent_id
                assert chunks[0]['revision'] == (3 if number_correction else 2)
                assert sum(chunk['sentence_id'] == child_id for chunk in chunks) == int(real_repeat)
                expected_sources = [corrected if number_correction else merged,
                                    *([second] if real_repeat else []), FOLLOWING]
                assert [chunk['text'] for chunk in chunks] == [
                    f'[English->Chinese] {source}' for source in expected_sources]
                if number_correction:
                    assert '15' not in ' '.join(chunk['text'] for chunk in chunks)
                    assert '50 USD' in chunks[0]['text']
                rows = app.state.monitor.snapshot()['rows']
                spoken = [part for row in rows for part in row.get('spoken', [])]
                assert [part['source'] for part in spoken] == expected_sources
                expected = re.findall(r"\w+(?:['’]\w+)*", ' '.join(expected_sources).casefold())
                actual = re.findall(r"\w+(?:['’]\w+)*", ' '.join(p['source'] for p in spoken).casefold())
                assert actual == expected, 'every accepted source token must be published exactly once'
                superseded = [e for e in events if e.get('type') == 'sentence_superseded']
                assert len(superseded) == (0 if real_repeat else 1)
                if superseded:
                    assert superseded[0]['sentence_id'] == child_id
                    assert superseded[0]['revision'] == 1
                    assert superseded[0]['replacement_sentence_id'] == parent_id
                    assert superseded[0]['replacement_revision'] == 2
                assert app.state.speech_diagnostics() == []
            finally:
                unblock.set()
