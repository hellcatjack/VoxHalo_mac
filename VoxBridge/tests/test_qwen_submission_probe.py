import pytest


def test_probe_reports_recognized_unit_wait_not_caption_gap_or_source_latency():
    from tools.benchmark_qwen_submission import summarize
    rows = [
        {"wall_sec": 1, "event": {"type": "partial", "text": "我们感谢", "stability": {"segment_id": 1}}},
        {"wall_sec": 2, "event": {"type": "partial", "text": "我们感谢上帝。后文", "stability": {"segment_id": 1}}},
        {"wall_sec": 5, "event": {"type": "sentence_committed", "text": "我们感谢上帝。", "stability": {"segment_id": 1}}},
        {"wall_sec": 7, "event": {"type": "final", "text": "我们感谢上帝。后文"}},
    ]
    result = summarize(rows, [
        {"seconds": .1, "decode_advance": 0},
        {"seconds": .2, "decode_advance": 1},
        {"seconds": .4, "decode_advance": 3},
    ])
    assert result["actual_decodes"] == 4
    assert result["observed_decode_calls"] == 2
    assert result["decode_batch_sec"]["max"] == .4
    assert result["recognized_unit_wait_sec"]["p95"] == 3
    assert result["oldest_recognized_pending_age_sec"]["p95"] == 4
    assert result["source_to_commit_latency_sec"] is None
    assert result["final_text"] == "我们感谢上帝。后文"


@pytest.mark.parametrize("rows", [[], [{"wall_sec": 1, "event": {"type": "error", "message": "failed"}}]])
def test_probe_rejects_incomplete_or_failed_runs(rows):
    from tools.benchmark_qwen_submission import summarize
    with pytest.raises(ValueError):
        summarize(rows, [])


def test_probe_never_matches_a_repeated_phrase_in_an_old_segment():
    from tools.benchmark_qwen_submission import summarize
    rows = [
        {"wall_sec": 1, "event": {"type": "partial", "text": "感谢上帝。", "stability": {"segment_id": 1}}},
        {"wall_sec": 10, "event": {"type": "partial", "text": "感谢上帝。", "stability": {"segment_id": 2}}},
        {"wall_sec": 12, "event": {"type": "sentence_committed", "text": "感谢上帝。", "stability": {"segment_id": 2}}},
        {"wall_sec": 13, "event": {"type": "final", "text": "感谢上帝。感谢上帝。"}},
    ]
    assert summarize(rows, [])["recognized_unit_wait_sec"]["max"] == 2
    assert summarize(rows, [])["oldest_recognized_pending_age_sec"]["max"] == 2


def test_benchmark_refuses_nonlocal_translation_or_missing_model():
    from tools.benchmark_qwen_submission import validate_local_config
    from types import SimpleNamespace
    with pytest.raises(ValueError, match="local"):
        validate_local_config(SimpleNamespace(asr_model_path="/missing", translation_api_base_url="https://example.com/v1"))


def test_probe_keeps_full_committed_transcript_after_window_rotation():
    from tools.benchmark_qwen_submission import summarize
    rows = [{"wall_sec": 45, "event": {"type": "final", "text": "最后一段。",
             "committed_text": "第一段。第二段。最后一段。", "tentative_text": ""}}]
    assert summarize(rows, [])["final_text"] == "第一段。第二段。最后一段。"


def test_probe_accepts_stop_after_empty_rotated_window_with_committed_text():
    from tools.benchmark_qwen_submission import summarize
    rows = [{"wall_sec": 46, "event": {"type": "final", "text": "", "committed_text": "前一段已经完整提交。"}}]
    assert summarize(rows, [])["final_text"] == "前一段已经完整提交。"
