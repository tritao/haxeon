#!/usr/bin/env python3
import json
import sys


def flatten(value, prefix=""):
    rows = {}
    if isinstance(value, (int, float)):
        rows[prefix] = value
    elif isinstance(value, dict):
        if "median" in value and isinstance(value["median"], (int, float)):
            rows[prefix] = value["median"]
        else:
            for key, child in value.items():
                rows.update(flatten(child, f"{prefix}/{key}" if prefix else key))
    return rows


if len(sys.argv) != 3:
    raise SystemExit("usage: benchmark-compare.py BASELINE.json CANDIDATE.json")

with open(sys.argv[1], encoding="utf-8") as source:
    baseline = flatten(json.load(source).get("results", {}))
with open(sys.argv[2], encoding="utf-8") as source:
    candidate = flatten(json.load(source).get("results", {}))

print(f"{'metric':64} {'baseline':>12} {'candidate':>12} {'change':>10}")
for metric in sorted(baseline.keys() & candidate.keys()):
    old, new = baseline[metric], candidate[metric]
    change = "n/a" if old == 0 else f"{(new - old) * 100 / old:+.1f}%"
    print(f"{metric:64} {old:12.3f} {new:12.3f} {change:>10}")
