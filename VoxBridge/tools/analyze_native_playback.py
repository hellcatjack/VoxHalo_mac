"""Summarize NativeVideoPlaybackChecks telemetry without counting generation wait as removable silence."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics


def analyze(directory: Path) -> dict:
    samples = [json.loads(line) for line in (directory / "timeline.jsonl").read_text().splitlines()]
    cues: dict[str, dict] = {}
    first_seen: dict[str, float] = {}
    first_seekable: dict[str, float] = {}
    opportunities: dict[str, dict] = {}
    events: dict[str, dict] = {}
    latest: list[dict] = []
    previous_sample = None
    removable_wait = 0.0
    for sample in samples:
        for event in sample.get("gap_events", []):
            events[event["cue_id"]] = event
        if "captions" in sample:
            latest = sample["captions"].get("cues", [])
            for cue in latest:
                cues[cue["cue_id"]] = cue
                first_seen.setdefault(cue["cue_id"], sample["elapsed"])
        at = sample.get("program_ms")
        if at is None:
            continue
        for cue in latest:
            if cue["cue_id"] in first_seekable:
                continue
            target = sample["media_time"] + (cue["start_at_ms"] - 250 - at) / 1000
            guard = sample["media_time"] + (cue["start_at_ms"] + 100 - at) / 1000
            if any(start <= target <= end and start <= guard <= end for start, end in sample["seekable"]):
                first_seekable[cue["cue_id"]] = sample["elapsed"]
        index = next((i for i, cue in enumerate(latest) if cue["start_at_ms"] > at), None)
        if index is not None and index > 0:
            prev, nxt = latest[index - 1:index + 1]
            resume = nxt.get("resume_at_ms")
            if resume is not None and nxt["discardable_gap_before_ms"] >= 500 and prev["end_at_ms"] <= at < nxt["start_at_ms"]:
                remaining = max(0, nxt["start_at_ms"] - resume - (at - prev["end_at_ms"]))
                target = max(prev["end_at_ms"], min(nxt["start_at_ms"] - remaining, nxt["start_at_ms"] - 250))
                media_target = sample["media_time"] + (target - at) / 1000
                guard = sample["media_time"] + (nxt["start_at_ms"] + 100 - at) / 1000
                if target - at >= 500 and any(start <= media_target <= end and start <= guard <= end for start, end in sample["seekable"]):
                    opportunities.setdefault(nxt["cue_id"], {"elapsed": sample["elapsed"], "potential_skip_seconds": (target - at) / 1000})
                    if previous_sample is not None:
                        removable_wait += min(0.2, sample["elapsed"] - previous_sample["elapsed"])
        previous_sample = sample

    def crossing(program_ms: float) -> float | None:
        for sample in samples:
            if sample.get("program_ms", 0) >= program_ms:
                return sample["elapsed"]
        return None

    gaps = []
    ordered = sorted(cues.values(), key=lambda cue: cue["start_at_ms"])
    for previous, cue in zip(ordered, ordered[1:]):
        end, start = crossing(previous["end_at_ms"]), crossing(cue["start_at_ms"])
        if end is None or start is None:
            continue
        gaps.append({"cue_id": cue["cue_id"], "text": cue["text"], "playhead_gap_seconds": start - end,
                     "carrier_seconds": cue["discardable_gap_before_ms"] / 1000,
                     "natural_gap_seconds": (cue["start_at_ms"] - previous["end_at_ms"] - cue["discardable_gap_before_ms"]) / 1000,
                     "caption_ready_to_playhead_seconds": start - first_seen[cue["cue_id"]],
                     "next_seekable_before_previous_end": first_seekable.get(cue["cue_id"], float("inf")) <= end,
                     "opportunity": opportunities.get(cue["cue_id"]), "seek": events.get(cue["cue_id"])})
    heard = [gap["playhead_gap_seconds"] for gap in gaps]
    ready_gaps = [gap["playhead_gap_seconds"] for gap in gaps if gap["next_seekable_before_previous_end"]]
    unsafe_seeks = []
    for event in events.values():
        if event.get("finished") and any(
            event["from_ms"] < cue["end_at_ms"] and event["landed_ms"] > cue["start_at_ms"]
            for cue in ordered
        ):
            unsafe_seeks.append(event)
    report = {
        "cue_count": len(cues), "completed_gaps": len(gaps),
        "gaps_with_seekable_carrier": len(opportunities),
        "seekable_carrier_wait_seconds": round(removable_wait, 3),
        "gap_seek_count": len(events),
        "successful_gap_seeks": sum(bool(event.get("finished")) for event in events.values()),
        "requested_skip_seconds": round(sum(event["skip_seconds"] for event in events.values()), 3),
        "maximum_seek_wall_seconds": round(max((event["seek_wall_seconds"] for event in events.values()), default=0), 3),
        "seek_intervals_overlapping_speech_cues": unsafe_seeks,
        "median_playhead_gap_seconds": round(statistics.median(heard), 3) if heard else None,
        "maximum_playhead_gap_seconds": round(max(heard), 3) if heard else None,
        "gaps_with_next_sentence_already_seekable": len(ready_gaps),
        "median_gap_when_next_already_seekable_seconds": round(statistics.median(ready_gaps), 3) if ready_gaps else None,
        "maximum_gap_when_next_already_seekable_seconds": round(max(ready_gaps), 3) if ready_gaps else None,
        "gaps": gaps,
    }
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    result = analyze(args.directory)
    (args.directory / "gap-analysis.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({key: value for key, value in result.items() if key != "gaps"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
