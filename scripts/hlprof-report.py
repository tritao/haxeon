#!/usr/bin/env python3
"""Self and inclusive time by function from a Perfetto export written by `hlprof-live export --format perfetto`.

The plain `hlprof-live report` counts every sample, including threads that are only waiting, so half of a short
capture can be one parked worker. This report drops idle samples and can keep only the samples taken while a chosen
function is on the stack (`--within`), which is how a capture is narrowed to the frames of a workload without having
to line profiler time up with application time.

  hlprof-report.py editor.perfetto.json --within tests.HeadlessEditorProfile.submit --top 25
"""
import argparse
import collections
import json
import re
import sys

# Leaf functions that mean the thread was blocked, not working.
IDLE_LEAVES = ("sys.thread.Condition.wait", "sys.thread.Lock.wait", "sys.thread.Semaphore.acquire",
               "Sys.sleep", "sys.thread.Thread.readMessage", "sys.net.Socket.select")
GENERIC = re.compile(r"^\$generic:(?P<origin>[^\[]+)\[[^\]]*\]<(?P<arguments>.*)>$")
LAMBDA = re.compile(r"^\$lambda:(?P<owner>.+):(?P<id>\d+)$")


def short(name: str, keep: int = 2) -> str:
    """`$generic:a.b.C.m[layout]<class:a.b.D<>>` -> `C.m<D>`; dotted names keep their last `keep` parts."""
    match = LAMBDA.match(name)
    if match:
        return "lambda in " + short(match.group("owner"), keep)
    match = GENERIC.match(name)
    if match:
        arguments = re.findall(r"(?:class|enum|abstract|iface):([\w.$]+)|(\w+)", match.group("arguments"))
        shown = ",".join(short(first or second, 1) for first, second in arguments if first or second)
        return short(match.group("origin"), keep) + "<" + shown + ">"
    if "(" in name:
        return re.sub(r"\s*\(.*\)$", "", name)
    parts = name.split(".")
    return ".".join(parts[-keep:])


def load(path):
    with open(path) as handle:
        document = json.load(handle)
    events = document["traceEvents"] if isinstance(document, dict) else document
    for event in events:
        if event.get("cat") == "hl.sample" and "stack" in event.get("args", {}):
            yield event


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("perfetto")
    parser.add_argument("--within", action="append", default=[], metavar="FUNCTION",
                        help="keep only samples with FUNCTION (a substring of a frame name) on the stack; repeatable (any)")
    parser.add_argument("--keep-idle", action="store_true", help="do not drop samples whose leaf is a blocking wait")
    parser.add_argument("--top", type=int, default=25)
    parser.add_argument("--full-names", action="store_true", help="do not shorten package and generic names")
    parser.add_argument("--json", action="store_true", help="print machine-readable results")
    arguments = parser.parse_args()

    total = kept = idle = outside = 0
    self_count = collections.Counter()
    inclusive = collections.Counter()
    threads = collections.Counter()
    for event in load(arguments.perfetto):
        total += 1
        stack = event["args"]["stack"].split(";")
        if not arguments.keep_idle and stack[-1] in IDLE_LEAVES:
            idle += 1
            continue
        if arguments.within and not any(wanted in frame for frame in stack for wanted in arguments.within):
            outside += 1
            continue
        kept += 1
        threads[event.get("tid")] += 1
        self_count[stack[-1]] += 1
        for frame in set(stack):
            inclusive[frame] += 1

    label = (lambda name: name) if arguments.full_names else short
    if arguments.json:
        json.dump({"samples": total, "kept": kept, "idle": idle, "outside": outside,
                   "self": {label(name): count for name, count in self_count.most_common(arguments.top)},
                   "inclusive": {label(name): count for name, count in inclusive.most_common(arguments.top)}},
                  sys.stdout, indent=1)
        print()
        return 0

    print(f"samples={total} kept={kept} idle-dropped={idle} outside-window={outside}"
          + (f" within={'|'.join(arguments.within)}" if arguments.within else ""))
    if kept == 0:
        return 0
    dynamic = [name for name in self_count if "<Dynamic>" in name]
    print(f"\n  {'self':>6} {'incl':>6}  function")
    for name, count in self_count.most_common(arguments.top):
        print(f"  {100.0 * count / kept:5.1f}% {100.0 * inclusive[name] / kept:5.1f}%  {label(name)}")
    print(f"\n  {'incl':>6}  inclusive (top of the tree)")
    shown = 0
    for name, count in inclusive.most_common(arguments.top * 3):
        if name in ("__entry", "__init") or name.startswith("tests.") and count == kept:
            continue
        print(f"  {100.0 * count / kept:5.1f}%  {label(name)}")
        shown += 1
        if shown >= arguments.top:
            break
    if dynamic:
        print("\nDynamic generic instances among the self-time entries (boxed values on a hot path):")
        for name in dynamic:
            print(f"  {100.0 * self_count[name] / kept:5.1f}%  {label(name)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
