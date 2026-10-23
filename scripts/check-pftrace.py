#!/usr/bin/env python3
"""Validate a Perfetto .pftrace written by pftrace with trace_processor_shell.

Usage:
  check-pftrace.py --tp trace_processor_shell[.exe] TRACE
      [--expect-process NAME] [--expect-thread NAME ...] [--expect-slice NAME ...]
      [--expect-counter NAME ...] [--min-samples N] [--min-depth-fraction D:F]
      [--expect-frame SUBSTRING ...] [--expect-mixed]

Always asserts that the stats table has no error/data_loss rows with value > 0.
Runs one `trace_processor_shell -Q` invocation per query and parses the CSV output.
Exit status is 0 when every assertion holds, 1 otherwise, 2 on usage/tool errors.
Python 3 standard library only.
"""
import argparse
import csv
import subprocess
import sys


class ToolError(Exception):
    pass


def run_query(tp, trace, sql):
    """Runs one query; returns a list of dict rows (CSV header = keys)."""
    try:
        proc = subprocess.run([tp, "-Q", sql, trace], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True,
                              encoding="utf-8", errors="replace", timeout=600)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ToolError("cannot run %s: %s" % (tp, e))
    lines = [ln for ln in proc.stdout.splitlines()
             if ln.strip() and not ln.startswith("[") and not ln.startswith("Loading")]
    # progress text can be glued to the front of the first CSV line without a newline
    cleaned = []
    for ln in lines:
        idx = ln.find('"')
        if cleaned == [] and not ln.startswith('"') and idx >= 0 and "Loading" in ln[:idx]:
            ln = ln[idx:]
        cleaned.append(ln)
    if proc.returncode != 0:
        raise ToolError("trace_processor failed (rc=%d) for query:\n  %s\n%s"
                        % (proc.returncode, sql, proc.stderr.strip() or proc.stdout.strip()))
    if not cleaned:
        raise ToolError("no output from trace_processor for query:\n  %s\n%s"
                        % (sql, proc.stderr.strip()))
    rows = list(csv.reader(cleaned))
    header = rows[0]
    return [dict(zip(header, r)) for r in rows[1:]]


def sql_str(s):
    return "'" + s.replace("'", "''") + "'"


def scalar(tp, trace, sql):
    rows = run_query(tp, trace, sql)
    if not rows:
        return 0
    v = list(rows[0].values())[0]
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return 0


# A callsite is native when its frame's mapping name ends in .dll or .exe.
MIXED_SQL = """
with recursive info(id, parent_id, nat) as (
  select c.id, c.parent_id,
    coalesce((select 1 from stack_profile_frame f
              join stack_profile_mapping m on m.id = f.mapping
              where f.id = c.frame_id
                and (lower(m.name) like '%.dll' or lower(m.name) like '%.exe')), 0)
  from stack_profile_callsite c),
w(cur, st) as (
  select distinct callsite_id, 0 from stack_sample where callsite_id is not null
  union
  select i.parent_id,
    case when w.st = 0 and i.nat = 0 then 1
         when w.st = 1 and i.nat = 1 then 2
         when w.st = 2 and i.nat = 0 then 3
         else w.st end
  from w join info i on i.id = w.cur)
select count(*) as n from w where st = 3
"""


def main():
    ap = argparse.ArgumentParser(description="Validate a pftrace with trace_processor_shell")
    ap.add_argument("--tp", required=True, help="path to trace_processor_shell")
    ap.add_argument("trace")
    ap.add_argument("--expect-process", metavar="NAME")
    ap.add_argument("--expect-thread", action="append", default=[], metavar="NAME")
    ap.add_argument("--expect-slice", action="append", default=[], metavar="NAME")
    ap.add_argument("--expect-counter", action="append", default=[], metavar="NAME")
    ap.add_argument("--min-samples", type=int, default=0, metavar="N")
    ap.add_argument("--min-depth-fraction", metavar="D:F",
                    help="at least fraction F of samples have stack depth >= D")
    ap.add_argument("--expect-frame", action="append", default=[], metavar="SUBSTRING")
    ap.add_argument("--expect-mixed", action="store_true",
                    help="a sample stack goes Haxe -> native (.dll/.exe mapping) -> Haxe")
    args = ap.parse_args()

    tp, trace = args.tp, args.trace
    failures = []

    def check(ok, msg):
        if not ok:
            failures.append(msg)

    depth_req = None
    if args.min_depth_fraction:
        try:
            d, f = args.min_depth_fraction.split(":")
            depth_req = (int(d), float(f))
        except ValueError:
            print("bad --min-depth-fraction (want D:F, e.g. 3:0.5)", file=sys.stderr)
            return 2

    try:
        # import health
        bad = run_query(tp, trace,
                        "select name, idx, severity, source, value from stats "
                        "where severity in ('error','data_loss') and value > 0")
        for r in bad:
            check(False, "stats %s[%s] severity=%s value=%s"
                  % (r["name"], r["idx"], r["severity"], r["value"]))

        n_proc = scalar(tp, trace, "select count(*) from process where pid > 0")
        n_thread = scalar(tp, trace, "select count(*) from thread where tid > 0")
        n_slice = scalar(tp, trace, "select count(*) from slice")
        n_ctrack = scalar(tp, trace, "select count(*) from process_counter_track")
        n_cval = scalar(tp, trace, "select count(*) from counter c join process_counter_track t on c.track_id = t.id")
        n_samples = scalar(tp, trace, "select count(*) from stack_sample")
        n_frames = scalar(tp, trace, "select count(*) from stack_profile_frame")
        max_depth = scalar(tp, trace,
                           "select coalesce(max(c.depth), -1) + 1 from stack_sample s "
                           "join stack_profile_callsite c on c.id = s.callsite_id")

        if args.expect_process:
            n = scalar(tp, trace, "select count(*) from process where name = %s"
                       % sql_str(args.expect_process))
            check(n > 0, "process %r not found" % args.expect_process)
        for name in args.expect_thread:
            n = scalar(tp, trace, "select count(*) from thread where name = %s" % sql_str(name))
            check(n > 0, "thread %r not found" % name)
        for name in args.expect_slice:
            n = scalar(tp, trace, "select count(*) from slice where name = %s" % sql_str(name))
            check(n > 0, "slice %r not found" % name)
        for name in args.expect_counter:
            n = scalar(tp, trace,
                       "select count(*) from counter c join counter_track t on c.track_id = t.id "
                       "where t.name = %s" % sql_str(name))
            check(n > 0, "counter track %r not found or has no values" % name)
        for sub in args.expect_frame:
            n = scalar(tp, trace, "select count(*) from stack_profile_frame where instr(name, %s) > 0"
                       % sql_str(sub))
            check(n > 0, "no frame name contains %r" % sub)
        check(n_samples >= args.min_samples,
              "only %d samples, expected at least %d" % (n_samples, args.min_samples))
        if depth_req:
            d, f = depth_req
            n = scalar(tp, trace,
                       "select count(*) from stack_sample s join stack_profile_callsite c "
                       "on c.id = s.callsite_id where c.depth + 1 >= %d" % d)
            frac = (n / float(n_samples)) if n_samples else 0.0
            check(frac >= f, "only %.3f of samples have depth >= %d, expected >= %.3f" % (frac, d, f))
        mixed = None
        if args.expect_mixed:
            mixed = scalar(tp, trace, MIXED_SQL)
            check(mixed > 0, "no sample stack has the pattern Haxe -> native (.dll/.exe) -> Haxe")

        top = run_query(tp, trace,
                        "select f.name as name, count(*) as n from stack_sample s "
                        "join stack_profile_callsite c on c.id = s.callsite_id "
                        "join stack_profile_frame f on f.id = c.frame_id "
                        "group by f.name order by n desc, f.name limit 10")
    except ToolError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 2

    print("trace:    %s" % trace)
    print("processes=%d threads=%d slices=%d counter_tracks=%d counter_values=%d"
          % (n_proc, n_thread, n_slice, n_ctrack, n_cval))
    print("samples=%d distinct_frames=%d max_stack_depth=%d" % (n_samples, n_frames, max_depth))
    if mixed is not None:
        print("mixed (Haxe->native->Haxe) callsite chains: %d" % mixed)
    print("top leaf functions:")
    for r in top:
        print("  %8s  %s" % (r["n"], r["name"]))

    if failures:
        print("FAILED (%d):" % len(failures), file=sys.stderr)
        for m in failures:
            print("  - " + m, file=sys.stderr)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
