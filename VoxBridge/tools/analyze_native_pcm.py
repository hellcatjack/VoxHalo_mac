"""Measure native render timing with the same PCM speech-edge detector as HLS captions."""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from voxbridge.tts.hls import _pcm_activity_bounds_ms


def stats(values):
    values = sorted(values)
    return {"n": len(values), "median_seconds": round(statistics.median(values), 3) if values else None,
            "p90_seconds": round(values[max(0, (9 * len(values) + 9) // 10 - 1)], 3) if values else None,
            "max_seconds": round(max(values), 3) if values else None}


def analyze(directory: Path) -> dict:
    samples = [json.loads(line) for line in (directory / "timeline.jsonl").read_text().splitlines()]
    schedules, rows = {}, {}
    for sample in samples:
        for chunk in sample.get("pcm_chunks", []):
            schedules[chunk["seq"]] = dict(chunk)
        for row in sample.get("monitor", {}).get("rows", []):
            key = (row["id"], row["revision"])
            observed = sample.get("monitor_elapsed", sample["elapsed"])
            entry = rows.setdefault(key, {"source": row["source"], "committed": observed})
            if row.get("translation"):
                entry.setdefault("translated", observed)
                entry["translation"] = row["translation"]
    origin = samples[0]["wall_ms"] / 1000 - samples[0]["elapsed"]
    render = [s for s in samples if s.get("mode") == "pcm"]

    def crossing(frame, scheduled):
        previous = None
        for sample in render:
            if sample["elapsed"] < scheduled:
                continue
            at = sample["rendered_frame"]
            if at >= frame:
                if previous is not None and at > previous["rendered_frame"]:
                    fraction = (frame - previous["rendered_frame"]) / (at - previous["rendered_frame"])
                    return max(scheduled, previous["elapsed"] + fraction * (sample["elapsed"] - previous["elapsed"]))
                return max(scheduled, sample["elapsed"] - (at - frame) / 24000)
            previous = sample
        return None

    grouped = defaultdict(list)
    for seq, chunk in sorted(schedules.items()):
        pcm = (directory / f"chunk-{seq:06d}.pcm").read_bytes()
        assert len(pcm) // 2 == chunk["end_frame"] - chunk["start_frame"], "archive length differs from scheduled buffer"
        left, right = _pcm_activity_bounds_ms(pcm, sample_rate=24000)
        scheduled = chunk["scheduled_at_ms"] / 1000 - origin
        chunk["created"] = chunk["created_at_ms"] / 1000 - origin
        chunk["speech_start"] = crossing(chunk["start_frame"] + left * 24, scheduled)
        chunk["speech_end"] = crossing(chunk["start_frame"] + right * 24, scheduled)
        chunk["buffer_end"] = crossing(chunk["end_frame"], scheduled)
        grouped[(chunk["sentence_id"], chunk["revision"])].append(chunk)

    sentences = []
    for key, chunks in grouped.items():
        assert [c["index"] for c in chunks] == list(range(chunks[0]["count"])), "incomplete or reordered sentence"
        sentences.append({"id": key[0], "revision": key[1], "source_order": chunks[0]["source_order"],
                          **rows.get(key, {}), "first_pcm": chunks[0]["created"],
                          "speech_start": chunks[0]["speech_start"], "speech_end": chunks[-1]["speech_end"],
                          "chunks": len(chunks)})
    sentences.sort(key=lambda s: s["source_order"])
    gaps = []
    for prev, nxt in zip(sentences, sentences[1:]):
        if prev["speech_end"] is None or nxt["speech_start"] is None:
            continue
        gaps.append({"id": nxt["id"], "seconds": nxt["speech_start"] - prev["speech_end"],
                     "next_pcm_ready": nxt["first_pcm"] <= prev["speech_end"],
                     "next_translation_ready": nxt.get("translated", float("inf")) <= prev["speech_end"]})
    ordered = list(schedules.values())
    schedule_gaps = [(nxt["start_frame"] - prev["end_frame"]) / 24000 for prev, nxt in zip(ordered, ordered[1:])]
    return {"chunk_count": len(schedules), "sentence_count": len(sentences),
            "completed_sentence_count": sum(s["speech_end"] is not None for s in sentences),
            "inter_chunk_schedule_gaps": stats(schedule_gaps),
            "sentence_speech_gaps": stats([g["seconds"] for g in gaps]),
            "ready_sentence_gaps": stats([g["seconds"] for g in gaps if g["next_pcm_ready"]]),
            "gaps_at_least_two_seconds": sum(g["seconds"] >= 2 for g in gaps),
            "long_gaps_translation_already_ready": sum(g["seconds"] >= 2 and g["next_translation_ready"] for g in gaps),
            "source_commit_to_first_speech": stats([s["speech_start"] - s["committed"] for s in sentences if s["speech_start"] is not None and "committed" in s]),
            "translation_to_first_pcm": stats([s["first_pcm"] - s["translated"] for s in sentences if "translated" in s]),
            "maximum_buffered_seconds": round(max((s.get("buffered_ms", 0) for s in render), default=0) / 1000, 3),
            "limitations": ["Render progress is sampled about every 100 ms; this is not a physical output recording.",
                            "Monitor source/translation observations are sampled about every 500 ms.",
                            "Source commit is not spoken sentence end. No source-end alignment was recorded.",
                            "Speech gaps use the same 10 ms PCM energy detector as HLS captions, including natural and deliberate sentence pauses."],
            "sentences": sentences, "gaps": gaps, "chunks": ordered}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    result = analyze(args.directory)
    (args.directory / "pcm-analysis.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k not in ("sentences", "gaps", "chunks")}, ensure_ascii=False, indent=2))
