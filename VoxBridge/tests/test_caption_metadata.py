"""Presentation proof must preserve ordered occurrences and never change audio."""
from copy import deepcopy
import json

import numpy as np
import pytest
from fastapi.testclient import TestClient

from voxbridge.cli.demo_streaming_ws import (
    _caption_canonical_range, _caption_reset_metadata, _caption_source_tokens, _create_app,
)
from voxbridge.streaming.source_ledger import SourceLedger, SourceSpan
from test_demo_streaming_ws_protocol import (
    _FakeASR, _FakeTranslator, _args, _collect_through_final, _receive_until_type,
)


def test_caption_reset_snapshot_keeps_repeated_occurrences_and_all_source_rows():
    items = [dict(id=f"s{index}", revision=1, zh="We agree.", en="译文", secret="excluded")
             for index in range(501)]
    before = deepcopy(items)
    metadata = _caption_reset_metadata(items, reset_id="r", old_epoch=7, new_epoch=8,
                                       canonical_source="We agree. " * len(items))
    assert metadata["caption_snapshot_complete"] is True
    assert len(metadata["previous_source_rows"]) == 501
    assert metadata["previous_source_tokens"] == metadata["canonical_replacement_tokens"]
    assert metadata["previous_source_rows"][0]["source_begin"] == 0
    assert metadata["previous_source_rows"][-1]["source_begin"] == 1000
    assert metadata["previous_source_rows"][-1]["source_end"] == 1002
    assert [row["order"] for row in metadata["previous_source_rows"]] == list(range(501))
    assert "excluded" not in json.dumps(metadata) and "译文" not in json.dumps(metadata, ensure_ascii=False)
    assert items == before


@pytest.mark.parametrize("source", ["Don't pay 12.50 today! 今天可以。", "ÉCOUTEZ-moi l’été.",
                                    "日本語も読めます。", "आज बात करें।", "Olá! ¿Cómo estás?"])
def test_caption_normalization_matches_occurrence_lexer_without_mutating_ledger(source):
    ledger = SourceLedger()
    ledger.observe(source, 1, raw=source)
    before = deepcopy({key: value for key, value in ledger.__dict__.items() if key != "_matches"})
    matches_before = tuple(ledger._matches)
    assert _caption_source_tokens(source) == ledger._words
    assert {key: value for key, value in ledger.__dict__.items() if key != "_matches"} == before
    assert tuple(ledger._matches) == matches_before


def test_caption_canonical_range_uses_bound_positions_for_real_repeats():
    source = "We agree. We agree."
    ledger = SourceLedger()
    ledger.observe(source, 1, raw=source)
    first, second = ledger.spans(["We agree.", "We agree."])
    words = _caption_source_tokens(source)
    assert _caption_canonical_range("We agree.", source, first, words) == (0, 2)
    assert _caption_canonical_range("We agree.", source, second, words) == (2, 4)
    assert _caption_canonical_range("We differ.", source, second, words) is None
    assert _caption_canonical_range("We agree.", source, second, words + ["extra"]) is None
    assert _caption_canonical_range("We agree.", source, None, words) is None
    assert _caption_canonical_range("We agree.", source,
                                    SourceSpan((1,), second.start, second.end), words) is None


def test_oversized_caption_snapshot_is_atomic_and_cannot_claim_partial_coverage():
    items = [dict(id="s", revision=1, zh="中文长句" * 1000)]
    metadata = _caption_reset_metadata(items, reset_id="r", old_epoch=1, new_epoch=2,
                                       canonical_source=items[0]["zh"], max_bytes=1024)
    assert metadata["caption_snapshot_complete"] is False
    assert metadata["caption_snapshot_omitted"] == "message_size"
    assert metadata["previous_source_rows"] is None
    assert metadata["previous_source_tokens"] is None
    assert metadata["canonical_replacement_tokens"] is None
    assert len(json.dumps(metadata).encode()) < 1024


def test_mt_token_epoch_changes_on_tts_reset_without_sentence_reset():
    first = "We first explain this complete message clearly to everyone."
    second = "Then we continue this second message without losing any words."
    third = "Finally we finish this third complete message for the audience."
    fourth = "Another complete sentence follows with sufficiently many useful words."

    class ToggleASR(_FakeASR):
        calls = 0

        def streaming_transcribe(self, wav, state):
            self.calls += 1
            state.audio_accum = np.concatenate((state.audio_accum, wav))
            state.language = "English"
            state.text = f"{first} {second} {third}" + (f" {fourth}" if self.calls >= 3 else "")
            return state

        def finish_streaming_transcribe(self, state):
            self.finish_calls += 1
            return state

    args = _args()
    args.final_redecode_on_stop = False
    args.early_translation_stable_sec = 0
    args.early_translation_stable_hits = 1
    events = []
    with TestClient(_create_app(args, ToggleASR(), translator=_FakeTranslator())).websocket_connect("/ws") as ws:
        ws.receive_json()
        ws.send_json(dict(type="start", translation_direction="en2zh", tts_enabled=False))
        _receive_until_type(ws, "started")
        for _ in range(2):
            ws.send_bytes(np.full(3200, 2000, dtype="<i2").tobytes())
            while True:
                event = ws.receive_json(); events.append(event)
                if event.get("type") == "partial":
                    break
        translated = [event for event in events if event["type"] == "sentence_translation"]
        if not translated:
            translated = [_receive_until_type(ws, "sentence_translation")]
        initial = translated[0]
        ws.send_json(dict(type="set_tts_enabled", enabled=False, tts_client_id="changed-client-1234"))
        assert _receive_until_type(ws, "tts_status")["status"] == "disabled"
        ws.send_bytes(np.full(3200, 2000, dtype="<i2").tobytes())
        _receive_until_type(ws, "partial")
        ws.send_json(dict(type="finish", mode="stop"))
        after = _collect_through_final(ws)
    later = [event for event in after if event["type"] == "sentence_translation"]
    assert later and all(event["source_token_epoch"] == initial["source_token_epoch"] + 1 for event in later)
    # TTS configuration can restart token identities inside the same source-ID
    # namespace. A sentence-reset-only epoch cannot safely identify coverage.
    namespace = initial["sentence_id"].rsplit("-", 1)[0]
    assert all(event["sentence_id"].rsplit("-", 1)[0] == namespace for event in later)
    assert not any(event["type"] == "sentence_reset" for event in events + after)


def test_ws_stop_redecode_exposes_previous_rows_and_exact_new_source_ranges():
    first = "We first explain this complete message clearly to everyone."
    second = "Then we continue this second message without losing any words."
    canonical = f"{first} {second} Finally we finish the complete account."

    class CaptionASR(_FakeASR):
        transcribe_language = "English"
        transcribe_text = canonical

        def streaming_transcribe(self, wav, state):
            state.audio_accum = np.concatenate((state.audio_accum, wav))
            state.language, state.text = "English", canonical
            return state

        def finish_streaming_transcribe(self, state):
            self.finish_calls += 1
            return state

    args = _args()
    args.final_redecode_on_stop = True
    args.final_redecode_max_sec = 30
    args.early_translation_stable_sec = 0
    args.early_translation_stable_hits = 1
    asr, translator = CaptionASR(), _FakeTranslator()
    events = []
    with TestClient(_create_app(args, asr, translator=translator)).websocket_connect("/ws") as ws:
        ws.receive_json()
        ws.send_json(dict(type="start", translation_direction="en2zh", tts_enabled=False))
        _receive_until_type(ws, "started")
        for _ in range(2):
            ws.send_bytes(np.full(3200, 2000, dtype="<i2").tobytes())
            while True:
                event = ws.receive_json(); events.append(event)
                if event.get("type") == "partial":
                    break
        ws.send_json(dict(type="finish", mode="stop"))
        events.extend(_collect_through_final(ws))

    resets = [event for event in events if event["type"] == "sentence_reset"]
    assert [event["reason"] for event in resets] == ["final_redecode", "final_commit_reconcile"]
    assert len({event["caption_reset_id"] for event in resets}) == 2
    previous_boundary = 0
    for reset_index, reset in enumerate(resets):
        assert reset["caption_snapshot_complete"] is True
        assert reset["new_epoch"] == reset["old_epoch"] + 1
        position = events.index(reset)
        old_sources = [event for event in events[previous_boundary:position] if event["type"] == "sentence_committed"]
        assert old_sources and [row["id"] for row in reset["previous_source_rows"]] == [row["sentence_id"] for row in old_sources]
        assert reset["canonical_replacement_source"] == canonical
        assert reset["canonical_replacement_tokens"] == _caption_source_tokens(canonical)
        next_boundary = events.index(resets[reset_index + 1]) if reset_index + 1 < len(resets) else len(events)
        after = events[position + 1:next_boundary]
        translated = [event for event in after if event["type"] == "sentence_translation"]
        assert all(event["source_token_epoch"] == reset["new_epoch"] for event in translated)
        source_events = [event for event in after if event["type"] in {"sentence_committed", "sentence_updated"}]
        assert source_events
        for event in source_events:
            assert event["caption_reset_id"] == reset["caption_reset_id"]
            assert event["new_epoch"] == reset["new_epoch"]
            begin, end = event["source_begin"], event["source_end"]
            assert begin is not None and end is not None
            assert reset["canonical_replacement_tokens"][begin:end] == _caption_source_tokens(event["text"])
        previous_boundary = position + 1
    assert any(event["type"] == "sentence_translation" for event in events[events.index(resets[-1]) + 1:])
    assert not any(event["type"] in {"tts_job", "speech_committed"} for event in events)
    assert len(asr.transcribe_calls) == 1
