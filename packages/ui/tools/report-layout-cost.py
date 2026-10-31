#!/usr/bin/env python3
"""Summarize opt-in layout submit diagnostics from profile-editor launch logs."""

import argparse
from pathlib import Path
import statistics

from ui_cost_report import frame_index, read_frames


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
    frames, starts, measured = read_frames(path)
    grouped = {}
    for row in submissions:
        index = frame_index(path, starts, row["started"])
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
