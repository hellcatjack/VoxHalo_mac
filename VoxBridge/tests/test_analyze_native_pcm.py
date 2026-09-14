import importlib.util
import json
from pathlib import Path
import struct

SPEC = importlib.util.spec_from_file_location("analyze_native_pcm", Path(__file__).parents[1] / "tools/analyze_native_pcm.py")
MODULE = importlib.util.module_from_spec(SPEC)


def test_contiguous_chunks_preserve_sentence_pause_and_no_carrier(tmp_path):
    SPEC.loader.exec_module(MODULE)
    schedules = [dict(seq=1, sentence_id="a", revision=1, source_order=0, index=0, count=2,
                      start_frame=0, end_frame=24000, scheduled_at_ms=100000, created_at_ms=99900),
                 dict(seq=2, sentence_id="a", revision=1, source_order=0, index=1, count=2,
                      start_frame=24000, end_frame=55200, scheduled_at_ms=100200, created_at_ms=100100),
                 dict(seq=3, sentence_id="b", revision=1, source_order=1, index=0, count=1,
                      start_frame=55200, end_frame=86400, scheduled_at_ms=101000, created_at_ms=100900)]
    samples = [dict(elapsed=i / 10, wall_ms=100000 + i * 100, mode="pcm", rendered_frame=i * 2400,
                    buffered_ms=0, pcm_chunks=schedules if i == 0 else [],
                    monitor_elapsed=i / 10 + 0.07,
                    monitor={"rows": [{"id": "a", "revision": 1, "source": "甲", "translation": "A."}]}) for i in range(38)]
    (tmp_path / "timeline.jsonl").write_text("\n".join(map(json.dumps, samples)))
    tone = struct.pack("<h", 1000) * 24000
    for seq in range(1, 4):
        (tmp_path / f"chunk-{seq:06d}.pcm").write_bytes(tone + (bytes(14400) if seq > 1 else b""))
    result = MODULE.analyze(tmp_path)
    assert result["chunk_count"] == 3 and result["sentence_count"] == 2
    assert result["inter_chunk_schedule_gaps"]["max_seconds"] == 0
    assert result["sentence_speech_gaps"]["median_seconds"] == 0.3
    assert result["ready_sentence_gaps"]["n"] == 1
    assert result["sentences"][0]["committed"] == 0.07


def test_missing_pcm_is_explicit(tmp_path):
    SPEC.loader.exec_module(MODULE)
    (tmp_path / "timeline.jsonl").write_text(json.dumps(dict(elapsed=0, wall_ms=0, mode="pcm",
        rendered_frame=0, pcm_chunks=[dict(seq=1)])))
    import pytest
    with pytest.raises(FileNotFoundError):
        MODULE.analyze(tmp_path)
