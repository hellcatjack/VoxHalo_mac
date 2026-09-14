import wave

import pytest


def test_probe_reads_only_requested_mono_pcm_window(tmp_path):
    from tools.benchmark_dual_asr import read_pcm_window

    path = tmp_path / "source.wav"
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        output.writeframes(b"\x01\x00" * 16000 + b"\x02\x00" * 16000)
    assert read_pcm_window(path, 1, 0.25) == b"\x02\x00" * 4000
    with pytest.raises(ValueError):
        read_pcm_window(path, 5, 1)


def test_probe_frame_deadlines_use_total_audio_not_incremental_processing_delay():
    from tools.benchmark_dual_asr import pcm_frames

    frames = list(pcm_frames(b"\x01\x00" * 8000, chunk_samples=3200))
    assert [len(raw) for raw, _ in frames] == [6400, 6400, 3200]
    assert [due for _, due in frames] == [0.2, 0.4, 0.5]


def test_report_distinguishes_first_partial_commit_and_final():
    from tools.benchmark_dual_asr import summarize_events

    events = [(10.1, {"type": "partial", "text": ""}),
              (10.5, {"type": "partial", "text": "你好"}),
              (12.0, {"type": "sentence_committed", "text": "你好世界", "sentence_id": "s1"}),
              (14.2, {"type": "final", "text": "你好世界", "committed_text": "你好世界"})]
    result = summarize_events(events, audio_started=10.0, input_seconds=4.0, decode_seconds=0.8)
    assert result["first_partial_sec"] == 0.5
    assert result["first_commit_sec"] == 2.0
    assert result["tail_finalize_sec"] == pytest.approx(0.2)
    assert result["decode_rtf"] == 0.2
    assert result["commits"] == 1
    assert result["final_text"] == "你好世界"
    with pytest.raises(RuntimeError, match="final"):
        summarize_events(events[:-1], audio_started=10.0, input_seconds=4, decode_seconds=0.8)
