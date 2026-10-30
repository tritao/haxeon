#!/usr/bin/env python3
"""Summarize opt-in layout submit diagnostics from profile-editor launch logs."""

import argparse
import bisect
import json
from pathlib import Path
import statistics


def read_submissions(path):
    pending = {}
    submissions = []
    for line in path.read_text().splitlines():
        if not line.startswith("layout-cost "):
            continue
        _, phase, *fields = line.split()
        values = dict(field.split("=", 1) for field in fields)
        nodes = int(values.pop("nodes"))
        if phase == "backend":
            if pending:
                raise ValueError(f"{path}: incomplete submission before backend record")
            pending["nodes"] = nodes
        elif not pending or pending["nodes"] != nodes:
            raise ValueError(f"{path}: unmatched {phase} record")
        pending.update({key: float(value) for key, value in values.items()})
        if phase == "haxe":
            if set(pending) != {"nodes", "encode", "prepare", "parse", "solve", "snapshot", "hash", "decode", "started"}:
                raise ValueError(f"{path}: incomplete submission: {pending}")
            submissions.append(pending)
            pending = {}
    if pending or not submissions:
        raise ValueError(f"{path}: incomplete or missing layout diagnostics")
    return submissions


def frame_costs(path, submissions):
    timeline = path.parent / "frame-timeline.jsonl"
    frames = [json.loads(line) for line in timeline.read_text().splitlines() if line.strip()]
    starts = [frame["startedAtSeconds"] for frame in frames]
    measured = set()
    seen = set()
    for index, frame in enumerate(frames):
        action = frame["action"]
        if action == "initial" or action.startswith(("setup:", "warm:", "verify:")):
            continue
        cycle = frame.get("cycle")
        if (cycle is None and action in seen) or (cycle is not None and cycle > 0):
            measured.add(index)
        seen.add(action)
    grouped = {}
    for row in submissions:
        index = bisect.bisect_right(starts, row["started"]) - 1
        if index < 0:
            raise ValueError(f"{path}: submission precedes the first frame")
        if row["started"] > starts[index] + frames[index]["frameSeconds"] + 0.00001:
            raise ValueError(f"{path}: submission is outside the recorded frame")
        if index not in measured:
            continue
        if index not in grouped:
            grouped[index] = {key: 0 for key in row}
            grouped[index]["passes"] = 0
        total = grouped[index]
        total["passes"] += 1
        total["nodes"] = max(total["nodes"], row["nodes"])
        for key in ("encode", "parse", "prepare", "solve", "snapshot", "hash", "decode"):
            total[key] += row[key]
    return list(grouped.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path)
    args = parser.parse_args()
    print("| capture | active frames | passes/frame | nodes (min–max) | encode ms | parse ms | prepare ms | solve ms | snapshot ms | hash ms | decode ms |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for path in args.logs:
        rows = frame_costs(path, read_submissions(path))
        if not rows:
            parser.error(f"{path}: no active frames after warmup")
        counts = [row["nodes"] for row in rows]
        times = [f"{statistics.median(row[key] for row in rows) * 1000:.3f}"
                 for key in ("encode", "parse", "prepare", "solve", "snapshot", "hash", "decode")]
        passes = statistics.median(row["passes"] for row in rows)
        print(f"| {path.parent.name} | {len(rows)} | {passes:g} | {min(counts)}–{max(counts)} | " + " | ".join(times) + " |")


if __name__ == "__main__":
    main()
