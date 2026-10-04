"""Reconstruct an offline caption fixture from a recorded trace and GET snapshots.

The trace supplies timing, revision and text hashes. Snapshots supply the actual
text and occurrence token IDs. Missing versions are reported; later wording is
never substituted for a version that was not observed. This utility is not a
model, service or audio replay, and its output belongs in local artifacts.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
from pathlib import Path


def digest(text: str) -> str:
    return hashlib.md5(text.encode()).hexdigest()[:8]


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def prepare(recording: Path, output: Path, font_size: float) -> dict:
    trace = read_jsonl(recording / "trace.jsonl")
    observations = read_jsonl(recording / "live-observations.jsonl")
    versions = collections.defaultdict(list)
    for sample in observations:
        monitor = sample.get("monitor", {})
        for row in monitor.get("rows", []) + monitor.get("superseded_rows", []):
            key = row["id"], row.get("revision", 0)
            if row not in versions[key]:
                versions[key].append(row)
    peers = collections.Counter(row["peer"] for row in trace if row.get("event") == "start_applied")
    peer = peers.most_common(1)[0][0]
    trace = [row for row in trace if row.get("peer") == peer and isinstance(row.get("ts_ms"), int)]
    started = next(row for row in trace if row.get("event") == "ws_send" and row.get("type") == "started")
    origin = started["ts_ms"]
    registered = {
        (row["sentence_id"], row["revision"]): row["source_order"]
        for row in trace if row.get("event") == "tts_source_registered"
    }
    order_to_id = {order: sid for (sid, _), order in registered.items()}
    queued = {
        (row["sentence_id"], row["revision"]): row
        for row in trace if row.get("event") == "translation_queued"
    }
    events, missing, excluded_additions = [], [], []

    def append(row: dict, event: dict, offset: float = 0) -> None:
        events.append({"at": (row["ts_ms"] - origin) / 1000,
                       "trace_order": row["trace_seq"] + offset, "event": event})

    append(started, {"type": "started"})
    for row in trace:
        kind = row.get("event")
        if kind in {"sentence_new_commit", "sentence_upgrade_commit", "source_rows_reconciled"}:
            sid, revision = row["sentence_id"], row["revision"]
            source_hash = row.get("source_hash8") or queued.get((sid, revision), {}).get("src_hash8")
            matches = [version for version in versions[(sid, revision)]
                       if not source_hash or digest(version.get("source", "")) == source_hash]
            if not matches:
                missing.append({"type": "source", "id": sid, "revision": revision, "hash": source_hash})
                continue
            append(row, {"type": "sentence_committed" if kind == "sentence_new_commit" else "sentence_updated",
                         "sentence_id": sid, "revision": revision, "text": matches[0]["source"]})
            if kind == "source_rows_reconciled":
                for child in row["absorbed_ids"]:
                    child_revisions = [key[1] for key in versions if key[0] == child]
                    if not child_revisions:
                        missing.append({"type": "superseded", "id": child})
                        continue
                    append(row, {"type": "sentence_superseded", "sentence_id": child,
                                 "revision": max(child_revisions), "replacement_sentence_id": sid,
                                 "replacement_revision": revision}, 0.1)
        elif kind == "translation_done":
            sid, revision = row["sentence_id"], row["revision"]
            if ":addition:" in sid:
                # Audio-only additions emit no sentence_translation websocket
                # event and belong to reading history's speech supplementation.
                excluded_additions.append({"id": sid, "revision": revision})
                continue
            matches = [version for version in versions[(sid, revision)]
                       if digest(version.get("translation", "")) == row["out_hash8"]]
            if not matches:
                missing.append({"type": "translation", "id": sid, "revision": revision,
                                "hash": row["out_hash8"]})
                continue
            version = matches[-1]
            event = {"type": "sentence_translation", "sentence_id": sid, "revision": revision,
                     "translation": version["translation"], "is_stable": True}
            if version.get("source_token_ids"):
                event["source_token_ids"] = version["source_token_ids"]
            append(row, event)
        elif kind == "ws_send" and row.get("type") == "final":
            append(row, {"type": "final"})
    if missing:
        raise ValueError(f"Snapshot versions required by the trace are unavailable: {missing}")
    pcm_first = {}
    for row in trace:
        if row.get("event") != "tts_pcm_committed":
            continue
        sid = order_to_id.get(row["source_order"])
        if sid is None or ":addition:" in sid:
            continue
        if hashlib.sha256(sid.encode()).hexdigest()[:8] != row["sentence_hash8"]:
            raise ValueError(f"PCM source order did not resolve to the same recorded sentence: {row}")
        key = f"{sid}@{row['revision']}"
        pcm_first.setdefault(key, (row["ts_ms"] - origin) / 1000)
    events.sort(key=lambda event: (event["at"], event["trace_order"]))
    metadata = {
        "recording": str(recording), "origin_ms": origin,
        "reconstruction": "Exact trace commit/MT timing and revision plus hash-matched monitor snapshot text; not a captured websocket payload",
        "source_token_evidence": "Use source_token_ids only when present in the exact observed revision; otherwise fail open",
        "pcm_comparison": "Recorded shared PCM first publication; not physical output onset",
        "trace_sha256": hashlib.sha256((recording / "trace.jsonl").read_bytes()).hexdigest(),
        "observations_sha256": hashlib.sha256((recording / "live-observations.jsonl").read_bytes()).hexdigest(),
        "missing_versions": missing, "audio_only_additions_excluded": excluded_additions,
    }
    fixture = {"direction": "en2zh", "font_size": font_size, "width_fraction": 0.8,
               "screen_width": 1440, "screen_height": 900, "events": events,
               "pcm_first": pcm_first, "metadata": metadata}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(fixture, ensure_ascii=False, indent=2))
    return fixture


def prepare_native_pcm_bound(recording: Path, output: Path, font_size: float) -> dict:
    """Use exact accepted-PCM text/times as an availability upper bound only.

    This format has no MT-ready events. It exercises reading under historical
    cadence without pretending to measure a model or confirmation-stage gain.
    """
    report = json.loads(recording.read_text())
    history = {(row["id"], row.get("revision", 0)): row for row in report["history_after_stop"]}
    events, pcm_first, seen, excluded = [], {}, set(), []
    for chunk in report["chunks"]:
        key = chunk["sentence_id"], chunk.get("revision", 0)
        if key in seen:
            continue
        seen.add(key)
        full = chunk.get("schedule", {}).get("sentence_text")
        row = history.get(key)
        if chunk.get("index", 0) != 0 or not row or not full or row.get("translation") != full or ":addition:" in key[0]:
            excluded.append({"id": key[0], "revision": key[1]})
            continue
        at = chunk["elapsed"]
        events.append({"at": at, "event": {"type": "sentence_committed", "sentence_id": key[0],
                                            "revision": key[1], "text": row["source"]}})
        events.append({"at": at, "event": {"type": "sentence_translation", "sentence_id": key[0],
                                            "revision": key[1], "translation": full, "is_stable": True}})
        pcm_first[f"{key[0]}@{key[1]}"] = at
    events.sort(key=lambda event: event["at"])
    events.append({"at": max(report["elapsed_seconds"], events[-1]["at"]), "event": {"type": "final"}})
    metadata = {
        "recording": str(recording), "recording_sha256": hashlib.sha256(recording.read_bytes()).hexdigest(),
        "reconstruction": "Exact native accepted first-PCM time and full text, matched to the same final history revision; no earlier revision substituted",
        "ready_time_limitation": "MT completion time is unavailable. The replay makes text eligible only at original PCM acceptance, a conservative readiness upper bound. MT-to-display metrics must not be used as translation-delay evidence.",
        "pcm_comparison": "Native PCM acceptance timestamp, not publication or physical output onset",
        "source_seconds": report["source_seconds"], "excluded_unmatched_versions": excluded,
    }
    fixture = {"direction": report["direction"], "font_size": font_size, "width_fraction": 0.8,
               "screen_width": 1440, "screen_height": 900, "events": events,
               "pcm_first": pcm_first, "metadata": metadata}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(fixture, ensure_ascii=False, indent=2))
    return fixture


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--font-size", type=float, default=36)
    arguments = parser.parse_args()
    fixture = (prepare_native_pcm_bound if arguments.recording.is_file() else prepare)(
        arguments.recording, arguments.output, arguments.font_size)
    print(json.dumps({"events": len(fixture["events"]), "duration_seconds": fixture["events"][-1]["at"],
                      "pcm_versions": len(fixture["pcm_first"]), "output": str(arguments.output)}))
