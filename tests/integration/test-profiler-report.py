#!/usr/bin/env python3
"""hlprof-report drops idle samples, keeps only samples under --within, and shortens generic and lambda names."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/hlprof-report.py"


def sample(stack, tid=1):
    return {"ph": "i", "s": "t", "cat": "hl.sample", "name": stack.split(";")[-1], "pid": 1, "tid": tid, "ts": 0.0,
            "args": {"stack": stack}}


def report(events, *extra):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "trace.json"
        path.write_text(json.dumps({"traceEvents": events}))
        result = subprocess.run([sys.executable, str(SCRIPT), str(path), "--json", *extra], check=True,
                                capture_output=True, text=True)
    return json.loads(result.stdout)


def main():
    events = [sample("main;frame;work")] * 6 + [sample("main;frame;$generic:a.b.C.m[layout]<class:a.b.D<>>")] * 2
    events += [sample("main;wait;sys.thread.Condition.wait", 2)] * 10 + [sample("main;setup;load")] * 3
    everything = report(events)
    if everything["samples"] != 21 or everything["idle"] != 10:
        raise SystemExit(f"unexpected counts {everything}")
    framed = report(events, "--within", "frame")
    if (framed["kept"], framed["idle"], framed["outside"]) != (8, 10, 3):
        raise SystemExit(f"--within did not narrow the samples: {framed}")
    if framed["self"].get("C.m<D>") != 2 or framed["inclusive"].get("frame") != 8:
        raise SystemExit(f"names or counts are wrong: {framed}")
    kept_idle = report(events, "--keep-idle")
    if kept_idle["idle"] != 0 or kept_idle["kept"] != 21:
        raise SystemExit(f"--keep-idle still dropped samples: {kept_idle}")
    print("PASS: profile report filters idle and out-of-window samples and shortens names")


if __name__ == "__main__":
    main()
