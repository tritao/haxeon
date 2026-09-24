#!/usr/bin/env python3
"""Report slow named HashLink profiler spans and samples inside them."""

import argparse
import bisect
from collections import Counter, defaultdict
import json
from pathlib import Path


def analyze(trace):
    stacks = defaultdict(list)
    samples = defaultdict(list)
    spans = []
    dropped = 0
    for event in trace["traceEvents"]:
        tid = event.get("tid")
        category = event.get("cat")
        phase = event.get("ph")
        if category == "hl.sample":
            samples[tid].append(event)
        elif category == "hl.span" and phase == "B":
            stacks[tid].append(event)
        elif category == "hl.span" and phase == "E":
            if not stacks[tid]:
                raise ValueError(f"unmatched span end on thread {tid}: {event['name']}")
            start = stacks[tid].pop()
            if start["name"] != event["name"]:
                raise ValueError(f"mismatched span on thread {tid}: {start['name']} / {event['name']}")
            spans.append((start, event))
        elif category == "hl.diagnostics" and event.get("name") == "profile records dropped":
            dropped += event.get("args", {}).get("dropped", 0)
    incomplete = [event["name"] for thread in stacks.values() for event in thread]
    for thread_samples in samples.values():
        thread_samples.sort(key=lambda item: item["ts"])
    return spans, samples, dropped, incomplete


def report(trace, minimum_ms, top):
    spans, samples, dropped, incomplete = analyze(trace)
    sample_times = {tid: [item["ts"] for item in entries] for tid, entries in samples.items()}
    result = []
    for start, end in spans:
        duration_ms = (end["ts"] - start["ts"]) / 1000
        if duration_ms < minimum_ms:
            continue
        tid = start["tid"]
        entries = samples.get(tid, [])
        times = sample_times.get(tid, [])
        inside = entries[bisect.bisect_left(times, start["ts"]):bisect.bisect_right(times, end["ts"])]
        leaves = Counter(item["name"] for item in inside)
        result.append({
            "name": start["name"], "threadId": tid, "startUs": start["ts"],
            "durationMs": duration_ms, "sampleCount": len(inside),
            "gcStopSamples": sum(bool(item.get("args", {}).get("gc_stop")) for item in inside),
            "topLeaves": [{"name": name, "samples": count} for name, count in leaves.most_common(8)],
            "sampleStacks": [item.get("args", {}).get("stack", "") for item in inside],
        })
    result.sort(key=lambda item: item["durationMs"], reverse=True)
    return {"spanCount": len(spans), "droppedRecords": dropped,
            "incompleteSpans": incomplete, "slowSpans": result[:top]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path, help="Perfetto JSON exported by hlprof-live")
    parser.add_argument("--min-ms", type=float, default=10)
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = report(json.loads(args.trace.read_text()), args.min_ms, args.top)
    for span in result["slowSpans"]:
        leaves = ", ".join(f"{item['name']} ({item['samples']})" for item in span["topLeaves"][:4])
        print(f"{span['durationMs']:.1f}ms {span['name']} thread={span['threadId']} "
              f"samples={span['sampleCount']} GC={span['gcStopSamples']} {leaves}")
    print(f"spans={result['spanCount']} dropped={result['droppedRecords']} "
          f"incomplete={len(result['incompleteSpans'])}")
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
