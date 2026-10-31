"""Frame association and warmup exclusion shared by UI cost reports."""

import bisect
import json


def read_frames(log):
    path = log.parent / "frame-timeline.jsonl"
    frames = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    starts = [frame["startedAtSeconds"] for frame in frames]
    if not starts or starts != sorted(starts):
        raise ValueError(f"{path}: missing or unordered frame timestamps")
    measured, seen = set(), set()
    for index, frame in enumerate(frames):
        action = frame["action"]
        if action == "initial" or action.startswith(("setup:", "warm:", "verify:")):
            continue
        cycle = frame.get("cycle")
        if (cycle is None and action in seen) or (cycle is not None and cycle > 0):
            measured.add(index)
        seen.add(action)
    return frames, starts, measured


def frame_index(log, starts, started):
    index = bisect.bisect_right(starts, started) - 1
    if index < 0:
        raise ValueError(f"{log}: diagnostic precedes the first frame")
    return index
