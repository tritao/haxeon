#!/usr/bin/env python3
"""Builds StageCostMain with the checkout's compiler (release, with the checkout's src, stdlib and lib/haxeon-io) and prints
main-thread instructions per function and stage of a warm build, the stage driver (`IrFunctionStages.run`) against the bare
engine loop it is built on, per case.

    benchmarks/query-stages/measure.py [--stages 25] [--functions 9000] [--builds 4] [--cases held,held1,held3,cutoff]
                                       [--checkout DIR]

Counts are main-thread instructions:u (perf --per-thread, serial marking, on the performance cores), as perf-guard counts them,
taken only around the measured warm builds (the program waits on standard input before and after them).
"""
import argparse
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def guard(checkout):
    spec = importlib.util.spec_from_file_location("perf_guard", os.path.join(checkout, "scripts", "perf-guard.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build(pg, checkout, out):
    hl = pg.hashlink()
    tool = subprocess.run([os.path.join(checkout, "scripts", "haxeon"), "dev", "tool-path", pg.ENTRY], cwd=checkout,
                          check=True, text=True, stdout=subprocess.PIPE).stdout.strip()
    listing = os.path.join(out, "sources.txt")
    pg.list_sources(checkout, listing)
    with open(listing, "a") as file:
        file.write(os.path.relpath(os.path.join(HERE, "StageCostMain.hx"), checkout) + "\n")
    program = os.path.join(out, "stage-cost.hl")
    bench_root = os.path.relpath(HERE, checkout)
    command = [hl, tool, "--build-mode=release", "--entry=StageCostMain", f"--root={bench_root}"] + [
        f"--root={root}" for root in pg.SOURCE_ROOTS] + [f"--sources-file={listing}", f"--output={program}"]
    with open(os.path.join(out, "build.log"), "w") as log:
        subprocess.run(command, cwd=checkout, check=True, stdout=log, stderr=subprocess.STDOUT)
    return hl, program


def count(pg, hl, program, arguments):
    # perf sometimes attaches only after a short run is over and counts nothing: run it again.
    for _ in range(3):
        counted = count_once(pg, hl, program, arguments)
        if counted is not None:
            return counted
    raise SystemExit("perf counted nothing for " + " ".join(arguments))


def count_once(pg, hl, program, arguments):
    pin, prefix = pg.performance_cores()
    env = dict(os.environ, HL_GC_MARK_SERIAL="1")
    process = subprocess.Popen(pin + [hl, program] + arguments, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               text=True)
    if process.stdout.readline().strip() != "ready":
        raise SystemExit("the benchmark did not start")
    event = prefix + "instructions/u"
    counter = subprocess.Popen(["perf", "stat", "--per-thread", "-x,", "-e", event, "-p", str(process.pid)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    # perf needs a moment to attach before the measured builds start.
    subprocess.run(["sleep", "1"])
    process.stdin.write("\n")
    process.stdin.flush()
    if process.stdout.readline().strip() != "done":
        raise SystemExit("the benchmark failed")
    counter.send_signal(signal.SIGINT)
    _, errors = counter.communicate()
    process.stdin.write("\n")
    process.stdin.flush()
    process.wait()
    rows = [row.split(",") for row in errors.splitlines()]
    counts = [int(row[1]) for row in rows
              if len(row) > 3 and row[0].endswith(f"-{process.pid}") and row[1].isdigit() and row[3] == event]
    return sum(counts) if counts else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stages", type=int, default=25)
    parser.add_argument("--functions", type=int, default=9000)
    parser.add_argument("--builds", type=int, default=4)
    parser.add_argument("--cases", default="held,held1,held3,cutoff")
    parser.add_argument("--checkout", default=os.path.dirname(os.path.dirname(HERE)))
    parser.add_argument("--accesses", default="base,current,current2,contribute,holds,recompute,has")
    parser.add_argument("--program", help="a StageCostMain build to run instead of building one")
    parser.add_argument("--inliner", default="held,cutoff", help="the inliner's cases (`IrInliner.run`), per function")
    arguments = parser.parse_args()
    pg = guard(arguments.checkout)
    if pg.perf_unavailable():
        raise SystemExit("perf: " + pg.perf_unavailable())
    out = tempfile.mkdtemp(prefix="stage-cost-")
    if arguments.program:
        hl, program = pg.hashlink(), arguments.program
    else:
        hl, program = build(pg, arguments.checkout, out)
        print("built", program, flush=True)
    per = arguments.builds * arguments.functions * arguments.stages
    print(f"{'case':8} {'driver':>8} {'engine':>8}   instructions per function and stage of a warm build")
    for case in arguments.cases.split(","):
        row = []
        for driver in ("driver", "engine"):
            total = count(pg, hl, program, [driver, case, str(arguments.stages), str(arguments.functions),
                                            str(arguments.builds)])
            row.append(total / per)
        print(f"{case:8} {row[0]:8.0f} {row[1]:8.0f}", flush=True)
    if arguments.inliner:
        print(f"{'inliner':8} {'':>8} {'':>8}   instructions per function of a warm build")
        for case in arguments.inliner.split(","):
            total = count(pg, hl, program, ["inliner", case, "1", str(arguments.functions), str(arguments.builds)])
            print(f"{case:8} {total / (arguments.builds * arguments.functions):8.0f}", flush=True)
    if not arguments.accesses:
        return 0
    print(f"{'access':12} {'per key':>8}   instructions per access, beyond base (base: newRevision and a put of the same function, per key)")
    keys = arguments.builds * arguments.functions
    base = None
    for access in arguments.accesses.split(","):
        total = count(pg, hl, program, ["access", access, "0", str(arguments.functions), str(arguments.builds)]) / keys
        if access == "base":
            base = total
            print(f"{access:12} {total:8.0f}", flush=True)
        else:
            print(f"{access:12} {total - (base or 0):8.0f}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
