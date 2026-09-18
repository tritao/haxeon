#!/usr/bin/env python3
"""Compare benchmark reports and optionally fail on measurable regressions."""

import argparse
import json
import math
import sys


WORK_FIELDS = {
    "modulesInvalidated",
    "modulesAnalyzed",
    "retypedFunctions",
    "retyped",
    "regenerated",
    "recoveredSnapshots",
}


def load_report(path):
    with open(path, encoding="utf-8") as source:
        report = json.load(source)
    # Older benchmark reports wrapped measurements in `results`; the editor
    # workload report stores them at the root. Keep both formats comparable.
    results = report.get("results")
    return results if isinstance(results, dict) else report


def flatten(value, prefix="", rows=None):
    if rows is None:
        rows = {}
    if isinstance(value, bool):
        return rows
    if isinstance(value, (int, float)):
        if prefix:
            rows[prefix] = float(value)
        return rows
    if isinstance(value, dict):
        for key, child in value.items():
            child_prefix = f"{prefix}/{key}" if prefix else key
            flatten(child, child_prefix, rows)
    return rows


def metric_category(path):
    parts = path.split("/")
    fields = set(parts)
    leaf = parts[-1]
    if fields & {
        "memoryGrowthBytes",
        "longLivedMemoryGrowthBytes",
        "rssGrowthKb",
        "heapGrowthBytes",
        "artifactBytes",
    }:
        return "memory"
    if "reusedClasses" in fields:
        return "reuse"
    if fields & WORK_FIELDS or "recoveredSnapshots" in fields:
        return "work"
    if any(part.endswith("Ms") for part in parts) or leaf in {"elapsed", "latency"}:
        return "latency"
    return None


def metrics(report):
    result = {}
    for path, value in flatten(report).items():
        category = metric_category(path)
        if category is not None:
            result[path] = (value, category)
    return result


def tolerance_for(category, options):
    if category == "work":
        return options.work_tolerance
    if category == "latency":
        return options.latency_tolerance_pct / 100.0
    if category == "memory":
        return options.memory_tolerance_pct / 100.0
    if category == "reuse":
        return options.reuse_tolerance_pct / 100.0
    return 0.0


def regression(old, new, category, options):
    if not math.isfinite(old) or not math.isfinite(new) or old < 0 or new < 0:
        return False
    if category == "reuse":
        if old == 0:
            return False
        return new < old * (1.0 - tolerance_for(category, options))
    if category == "work":
        return new > old + tolerance_for(category, options)
    allowed = max(options.absolute_tolerance, abs(old) * tolerance_for(category, options))
    return new > old + allowed


def direction_change(old, new, category):
    if old == new:
        return "UNCHANGED"
    if category == "reuse":
        return "IMPROVEMENT" if new > old else "DEGRADATION"
    return "IMPROVEMENT" if new < old else "DEGRADATION"


def format_value(value):
    if value == -1:
        return "n/a"
    if value.is_integer():
        return str(int(value))
    return f"{value:.3f}"


def compare(baseline, candidate, options):
    baseline_metrics = metrics(baseline)
    candidate_metrics = metrics(candidate)
    common = sorted(baseline_metrics.keys() & candidate_metrics.keys())
    missing = sorted(baseline_metrics.keys() - candidate_metrics.keys())
    added = sorted(candidate_metrics.keys() - baseline_metrics.keys())
    rows = []
    regressions = []

    for path in common:
        old, old_category = baseline_metrics[path]
        new, new_category = candidate_metrics[path]
        category = old_category or new_category
        if old < 0 or new < 0:
            status = "UNAVAILABLE"
        else:
            status = direction_change(old, new, category)
            if regression(old, new, category, options):
                status = "REGRESSION"
                regressions.append(path)
        rows.append({
            "metric": path,
            "category": category,
            "baseline": old,
            "candidate": new,
            "change": None if old == 0 else (new - old) * 100.0 / abs(old),
            "status": status,
        })

    if missing and not options.allow_missing:
        regressions.extend(missing)

    return {
        "rows": rows,
        "missing": missing,
        "added": added,
        "regressions": regressions,
        "compared": len(common),
    }


def print_text(result, options):
    print(f"{'metric':72} {'category':>9} {'baseline':>12} {'candidate':>12} {'change':>10} status")
    for row in result["rows"]:
        change = "n/a" if row["change"] is None else f"{row['change']:+.1f}%"
        print(
            f"{row['metric'][:72]:72} {row['category']:>9} "
            f"{format_value(row['baseline']):>12} {format_value(row['candidate']):>12} "
            f"{change:>10} {row['status']}"
        )
    if result["missing"]:
        print("Missing from candidate:")
        for path in result["missing"]:
            print(f"  {path}")
    if result["added"]:
        print("Added in candidate:")
        for path in result["added"]:
            print(f"  {path}")
    print(
        f"Compared {result['compared']} metrics; "
        f"regressions {len(result['regressions'])}; "
        f"tolerances latency={options.latency_tolerance_pct:.1f}% "
        f"memory={options.memory_tolerance_pct:.1f}% "
        f"reuse={options.reuse_tolerance_pct:.1f}% "
        f"work={options.work_tolerance:g}"
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare Haxeon benchmark JSON reports and detect regressions."
    )
    parser.add_argument("baseline", help="baseline JSON report")
    parser.add_argument("candidate", help="candidate JSON report")
    parser.add_argument(
        "--latency-tolerance-pct",
        type=float,
        default=10.0,
        help="allowed relative latency increase (default: 10%%)",
    )
    parser.add_argument(
        "--memory-tolerance-pct",
        type=float,
        default=10.0,
        help="allowed relative memory-growth increase (default: 10%%)",
    )
    parser.add_argument(
        "--reuse-tolerance-pct",
        type=float,
        default=10.0,
        help="allowed relative decrease in reused classes (default: 10%%)",
    )
    parser.add_argument(
        "--work-tolerance",
        type=float,
        default=0.0,
        help="allowed absolute increase in invalidated/analyzed/retyped work (default: 0)",
    )
    parser.add_argument(
        "--absolute-tolerance",
        type=float,
        default=0.0,
        help="minimum native-unit tolerance for latency/memory/reuse metrics",
    )
    parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="report missing baseline metrics without failing",
    )
    parser.add_argument(
        "--report-only",
        action="store_true",
        help="never fail, even when regressions are found",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="output format (default: text)",
    )
    return parser.parse_args()


def main():
    options = parse_args()
    if min(
        options.latency_tolerance_pct,
        options.memory_tolerance_pct,
        options.reuse_tolerance_pct,
        options.work_tolerance,
        options.absolute_tolerance,
    ) < 0:
        raise SystemExit("tolerances cannot be negative")
    baseline = load_report(options.baseline)
    candidate = load_report(options.candidate)
    result = compare(baseline, candidate, options)
    if result["compared"] == 0:
        raise SystemExit("reports contain no comparable benchmark metrics")
    if options.format == "json":
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print_text(result, options)
    if result["regressions"] and not options.report_only:
        return 1
    return 0


if __name__ == "__main__":
	try:
		sys.exit(main())
	except BrokenPipeError:
		# Treat a consumer such as `head` closing a report pipe as a normal
		# termination instead of emitting a traceback from a benchmark helper.
		try:
			sys.stdout.close()
		except OSError:
			pass
		sys.exit(0)
