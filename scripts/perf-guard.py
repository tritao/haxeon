#!/usr/bin/env python3
"""Guards the cost of the compiler compiling itself against tests/perf/self-compile-baseline.json.

    scripts/perf-guard.py            measure, compare, fail on a regression beyond a metric's tolerance
    scripts/perf-guard.py --update   measure and write the measured values into the baseline (tolerances are kept)

Two compiles of the checkout's own sources, both in release mode: the tool-cache compiler builds the compiler, and that build,
which carries the checkout's own code generation, compiles the same sources again. The second compile is the one measured:
  allocated bytes   the driver's allocation phases summed (deterministic)
  collections       the driver phases' GC count
  peak RSS          the process's maximum resident set
  instructions      main-thread instructions:u from perf, when perf is installed and allowed; skipped otherwise
  wall              reported, never compared (noisy on a shared machine)

Measures on Linux x86-64 only, where the baseline was taken; elsewhere it says so and passes. A metric beyond its tolerance
below the baseline passes and asks for the baseline to be updated, so gains are locked in.
"""
import json
import os
import platform
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "tests", "perf", "self-compile-baseline.json")
SOURCE_ROOTS = ["src", "lib/haxeon-io", "stdlib"]
ENTRY = "compiler.tools.HaxeonCompiler"


def run(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, text=True, stdout=subprocess.PIPE, **kwargs).stdout


def hashlink():
    directory = run([os.path.join(ROOT, "scripts", "hashlink-path.sh")]).strip()
    paths = [os.path.join(ROOT, "out"), directory]
    if os.environ.get("LD_LIBRARY_PATH"):
        paths.append(os.environ["LD_LIBRARY_PATH"])
    os.environ["LD_LIBRARY_PATH"] = ":".join(paths)
    return os.path.join(directory, "hl")


def compile_command(hl, compiler, sources, output):
    return [hl, compiler, "--build-mode=release", f"--entry={ENTRY}"] + [f"--root={root}" for root in SOURCE_ROOTS] + [
        f"--sources-file={sources}", f"--output={output}"]


def perf_unavailable():
    if run(["sh", "-c", "command -v perf || true"]).strip() == "":
        return "perf is not installed"
    try:
        with open("/proc/sys/kernel/perf_event_paranoid") as source:
            level = int(source.read())
    except OSError:
        return "no perf_event_paranoid"
    if level > 2:
        return f"perf_event_paranoid is {level}"
    return None


def measure(hl, compiler, sources, output, log_path):
    """Runs one compile; returns its metrics."""
    env = dict(os.environ, HL_GC_MARK_SERIAL="1")
    skip = perf_unavailable()
    command, event = compile_command(hl, compiler, sources, output), "instructions:u"
    # On a hybrid CPU each core type has its own counter, multiplexed and extrapolated when the thread moves between them:
    # keep the compile on the performance cores and count theirs.
    hybrid = "/sys/bus/event_source/devices/cpu_core/cpus"
    if skip is None and os.path.exists(hybrid):
        with open(hybrid) as source:
            command, event = ["taskset", "-c", source.read().strip()] + command, "cpu_core/instructions/u"
    started = time.monotonic()
    with open(log_path, "w") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        counter = None
        if skip is None:
            counter = subprocess.Popen(["perf", "stat", "--per-thread", "-x,", "-e", event, "-p", str(process.pid)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
    wall = time.monotonic() - started
    metrics = {"peak_rss_bytes": usage.ru_maxrss * 1024, "wall_seconds": round(wall, 2)}
    if counter is not None:
        _, errors = counter.communicate()
        # One row per thread and core type: `comm-tid,count,...`; the main thread's tid is the pid.
        rows = [row.split(",") for row in errors.splitlines()]
        counts = [int(row[1]) for row in rows if len(row) > 1 and row[0].endswith(f"-{process.pid}") and row[1].isdigit()]
        if counts:
            metrics["main_thread_instructions"] = sum(counts)
        else:
            skip = "perf counted nothing: " + errors.strip().replace("\n", " ")[:200]
    with open(log_path) as source:
        log = source.read()
    if process.returncode != 0 or "driver allocation phases:" not in log:
        sys.stderr.write(log[-4000:])
        raise SystemExit(f"perf-guard: the measured compile failed (exit {process.returncode}); log: {log_path}")
    line = next(line for line in log.splitlines() if line.startswith("driver allocation phases:"))
    fields = dict(field.split("=", 1) for field in line.split(":", 1)[1].split())
    metrics["allocated_bytes"] = sum(int(value) for key, value in fields.items() if key.endswith("-bytes"))
    metrics["collections"] = sum(int(value) for key, value in fields.items() if key.endswith("-gcs"))
    return metrics, skip


def main(arguments):
    update = arguments == ["--update"]
    if arguments and not update:
        raise SystemExit(__doc__)
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        print(f"perf-guard: skipped on {platform.system()} {platform.machine()}; the baseline is for Linux x86-64")
        return 0
    out = os.environ.get("HAXEON_SUITE_OUT") or os.path.join(ROOT, "out", "perf-guard")
    os.makedirs(out, exist_ok=True)
    hl = hashlink()
    tool = os.environ.get("HAXEON_COMPILER_HL") or run([os.path.join(ROOT, "scripts", "haxeon"), "dev", "tool-path", ENTRY]).strip()
    sources = os.path.join(out, "sources.txt")
    with open(sources, "w") as listing:
        for root in SOURCE_ROOTS:
            for directory, _, names in sorted(os.walk(os.path.join(ROOT, root))):
                for name in sorted(names):
                    if name.endswith(".hx"):
                        listing.write(os.path.relpath(os.path.join(directory, name), ROOT) + "\n")
    compiler = os.path.join(out, "compiler.hl")
    with open(os.path.join(out, "build.log"), "w") as log:
        status = subprocess.run(compile_command(hl, tool, sources, compiler), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
    if status != 0:
        raise SystemExit(f"perf-guard: building the compiler failed (exit {status}); log: {os.path.join(out, 'build.log')}")
    metrics, skip = measure(hl, compiler, sources, os.path.join(out, "self-compile.hl"), os.path.join(out, "self-compile.log"))

    with open(BASELINE) as source:
        baseline = json.load(source)
    print(f"perf-guard: self-compile wall {metrics['wall_seconds']} s (not compared)")
    if skip:
        print(f"perf-guard: instructions skipped: {skip}")
    failures, improvements = [], []
    for name, entry in baseline["metrics"].items():
        if name not in metrics:
            continue
        value, expected = metrics[name], entry["value"]
        slack = entry["tolerance"] * expected if "tolerance" in entry else entry["tolerance_abs"]
        change = (value - expected) * 100.0 / expected if expected else 0.0
        verdict = "ok"
        if value > expected + slack:
            verdict = "REGRESSION"
            failures.append(name)
        elif value < expected - slack:
            verdict = "improved: update the baseline"
            improvements.append(name)
        print(f"  {name:26} {value:>16} baseline {expected:>16} {change:+6.2f}% (allowed +-{slack:.0f})  {verdict}")
        if update:
            entry["value"] = value
    if update:
        with open(BASELINE, "w") as target:
            json.dump(baseline, target, indent="\t")
            target.write("\n")
        print(f"perf-guard: wrote the measured values to {os.path.relpath(BASELINE, ROOT)}")
        return 0
    if improvements:
        print("perf-guard: better than the baseline beyond tolerance; lock the gain in with scripts/perf-guard.py --update "
              "and commit the baseline with the change")
    if failures:
        print(f"perf-guard: FAILED: {', '.join(failures)} regressed beyond tolerance (docs/DEVELOPMENT.md, Performance guard)")
        return 1
    print("perf-guard: passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
