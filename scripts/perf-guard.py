#!/usr/bin/env python3
"""Guards the cost of the compiler compiling a frozen copy of its sources, once and in a compile server, against
tests/perf/*-baseline.json.

    scripts/perf-guard.py                          measure, compare, fail on a regression beyond a metric's tolerance
    scripts/perf-guard.py --update                 measure and write the measured values into the baselines (tolerances are kept)
    scripts/perf-guard.py --only=incremental       only one part (self-compile or incremental), with or without --update

Two compiles, both in release mode: the tool-cache compiler builds the compiler from the checkout, and that build, which carries
the checkout's own code generation, compiles the frozen input: the compiler's sources at the revision the self-compile baseline
names (`input_revision`, extracted with git archive), the same for every checkout, so a change that adds code does not grow
what it is measured on. The second compile is the one measured:
  allocated bytes   the driver's allocation phases summed (deterministic)
  collections       the driver phases' GC count
  live bytes        live data at the phase boundaries (tables, IR, backend), from a heap census taken there in a second
                    run of the same compile (deterministic to a fraction of a megabyte)
  peak RSS          the process's maximum resident set, an outcome of the collection schedule: gated loosely
  instructions      main-thread instructions:u from perf, when perf is installed and allowed; skipped otherwise
  cycles            main-thread cycles:u beside them, reported, never compared (they vary with the machine's load)
  wall              reported, never compared (noisy on a shared machine)

The incremental part (tests/perf/incremental-baseline.json) runs that build's compile server (CompilerServer, which keeps its
session) on a copy of the frozen input, through a scripted series of builds: cold, two no-op rebuilds, a body-only edit of the
entry module made and taken back a few times, an edit to a widely used constructor's signature, then the body edit again. Per
build it reads allocated bytes (the driver's allocation phases), functions retyped, artifacts invalidated and functions
regenerated (deterministic), and wall (reported). A heap census after each build (live data at its end, pages only) gives the
session's live bytes after the last body edit before the signature edit and their growth over the last of those, which stays
near zero unless the session keeps something from every build.

Measures on Linux x86-64 only, where the baseline was taken; elsewhere it says so and passes. A metric beyond its tolerance
below the baseline passes and asks for the baseline to be updated, so gains are locked in.
"""
import json
import os
import platform
import shutil
import socket
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "tests", "perf", "self-compile-baseline.json")
INCREMENTAL_BASELINE = os.path.join(ROOT, "tests", "perf", "incremental-baseline.json")
SOURCE_ROOTS = ["src", "lib/haxeon-io", "stdlib"]
ENTRY = "compiler.tools.HaxeonCompiler"
SERVER_ENTRY = "compiler.tools.CompilerServer"


def run(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, text=True, stdout=subprocess.PIPE, **kwargs).stdout


def hashlink():
    directory = run([os.path.join(ROOT, "scripts", "hashlink-path.sh")]).strip()
    paths = [os.path.join(ROOT, "out"), directory]
    if os.environ.get("LD_LIBRARY_PATH"):
        paths.append(os.environ["LD_LIBRARY_PATH"])
    os.environ["LD_LIBRARY_PATH"] = ":".join(paths)
    return os.path.join(directory, "hl")


def compile_arguments(sources, output, entry=ENTRY):
    # The reports this reads (driver allocation phases) come at the diagnostic verbosity.
    return ["--build-mode=release", "--verbosity=diagnostic", f"--entry={entry}"] + [f"--root={root}" for root in SOURCE_ROOTS] + [
        f"--sources-file={sources}", f"--output={output}"]


def compile_command(hl, compiler, sources, output, entry=ENTRY):
    return [hl, compiler] + compile_arguments(sources, output, entry)


def list_sources(tree, listing_path):
    """Writes the `.hx` files under `tree`'s source roots, relative to it, to `listing_path`."""
    with open(listing_path, "w") as listing:
        for root in SOURCE_ROOTS:
            for directory, _, names in sorted(os.walk(os.path.join(tree, root))):
                for name in sorted(names):
                    if name.endswith(".hx"):
                        listing.write(os.path.relpath(os.path.join(directory, name), tree) + "\n")


def frozen_input(out):
    """The frozen input's tree (made once per revision) and its source listing."""
    with open(BASELINE) as source:
        revision = json.load(source)["input_revision"]
    tree = os.path.join(out, "input-" + revision[:12])
    if not os.path.exists(os.path.join(tree, "sources.txt")):
        shutil.rmtree(tree, ignore_errors=True)
        os.makedirs(tree)
        archive = subprocess.run(["git", "archive", revision] + SOURCE_ROOTS, cwd=ROOT, check=True, stdout=subprocess.PIPE).stdout
        subprocess.run(["tar", "-x", "-C", tree], input=archive, check=True)
        list_sources(tree, os.path.join(tree, "sources.txt"))
    return tree, os.path.join(tree, "sources.txt")


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


def measure(hl, compiler, sources, output, log_path, cwd):
    """Runs one compile in `cwd`; returns its metrics."""
    env = dict(os.environ, HL_GC_MARK_SERIAL="1")
    skip = perf_unavailable()
    command, prefix = compile_command(hl, compiler, sources, output), ""
    # On a hybrid CPU each core type has its own counter, multiplexed and extrapolated when the thread moves between them:
    # keep the compile on the performance cores and count theirs.
    hybrid = "/sys/bus/event_source/devices/cpu_core/cpus"
    if skip is None and os.path.exists(hybrid):
        with open(hybrid) as source:
            command, prefix = ["taskset", "-c", source.read().strip()] + command, "cpu_core/"
    events = {prefix + "instructions/u": "main_thread_instructions", prefix + "cycles/u": "main_thread_cycles"}
    started = time.monotonic()
    with open(log_path, "w") as log:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
        counter = None
        if skip is None:
            counter = subprocess.Popen(["perf", "stat", "--per-thread", "-x,", "-e", ",".join(events), "-p", str(process.pid)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
    wall = time.monotonic() - started
    metrics = {"peak_rss_bytes": usage.ru_maxrss * 1024, "wall_seconds": round(wall, 2)}
    if counter is not None:
        _, errors = counter.communicate()
        # One row per thread, core type and event: `comm-tid,count,unit,event,...`; the main thread's tid is the pid.
        rows = [row.split(",") for row in errors.splitlines()]
        for event, name in events.items():
            counts = [int(row[1]) for row in rows
                      if len(row) > 3 and row[0].endswith(f"-{process.pid}") and row[1].isdigit() and row[3] == event]
            if counts:
                metrics[name] = sum(counts)
        if "main_thread_instructions" not in metrics:
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


BOUNDARIES = ["tables", "ir", "backend"]


def measure_live(hl, compiler, sources, output, log_path, cwd):
    """Runs the compile again in `cwd` with a heap census at each phase boundary; returns the live bytes there."""
    env = dict(os.environ, HL_GC_MARK_SERIAL="1", HAXEON_PEAK_CENSUS=",".join(f"{name}-end" for name in BOUNDARIES))
    with open(log_path, "w") as log:
        status = subprocess.run(compile_command(hl, compiler, sources, output), cwd=cwd, env=env, stdout=log,
                                stderr=subprocess.STDOUT).returncode
    with open(log_path) as source:
        log = source.read()
    if status != 0:
        sys.stderr.write(log[-4000:])
        raise SystemExit(f"perf-guard: the census compile failed (exit {status}); log: {log_path}")
    metrics = {}
    for line in log.splitlines():
        # `census ir-end total mapped M MB resident R MB live L MB ...`
        words = line.split()
        if len(words) > 3 and words[0] == "census" and words[2] == "total" and "live" in words:
            name = words[1][:-len("-end")] if words[1].endswith("-end") else words[1]
            metrics[f"live_bytes_{name}"] = round(float(words[words.index("live") + 1]) * 1024 * 1024)
    missing = [name for name in BOUNDARIES if f"live_bytes_{name}" not in metrics]
    if missing:
        raise SystemExit(f"perf-guard: no census at the {', '.join(missing)} boundary; log: {log_path}")
    return metrics


# The edits the incremental part makes to its copy of the sources: each `old` occurs exactly once in its file. When the code they
# anchor on changes, pick another anchor of the same kind and update the incremental baseline.
BODY_EDIT = ("src/compiler/tools/HaxeonCompiler.hx", '"haxeon compiler: "', '"haxeon compiler! "')
SIGNATURE_EDIT = ("src/compiler/core/InternalError.hx", "?previous:haxe.Exception) {",
                  "?previous:haxe.Exception, ?guardEdit:Int) {")
# The body edit is made and taken back this many times, before the signature edit: the session's live bytes settle within the
# first few, and their growth is read over the last GROWTH_BUILDS, an even count so both ends build the same sources.
BODY_EDITS = 6
GROWTH_BUILDS = 2
# After the signature edit, the body edit again: the session now holds the rewrites of the constructor's many callers, which a
# body edit must reuse rather than redo. The second is measured, once the edit has settled.
LATE_BODY_EDITS = 2


class CompileServer:
    """A compile server on a copy of the sources, driven over its protocol (compiler.tools.CompilerServerProtocol)."""

    def __init__(self, hl, server, tree, log_path):
        self.tree, self.log_path = tree, log_path
        state = os.path.join(tree, "server.json")
        # The census at the end of each build (`write-done`) collects first and reports the live data per size class only;
        # the explanation of each build's invalidation names what it retyped and regenerated.
        env = dict(os.environ, HL_GC_MARK_SERIAL="1", HAXEON_PEAK_CENSUS="write-done", HL_GC_CENSUS_PAGES_ONLY="1",
                   HAXEON_EXPLAIN_INVALIDATION="1", HAXEON_COMPILER_IDLE_SECONDS="900")
        self.log = open(log_path, "w")
        self.offset = 0
        self.process = subprocess.Popen([hl, server, state], cwd=tree, env=env, stdin=subprocess.DEVNULL, stdout=self.log,
                                        stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 60
        while not os.path.exists(state):
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise SystemExit(f"perf-guard: the compile server did not start; log: {log_path}")
            time.sleep(0.05)
        with open(state) as source:
            self.state = json.load(source)

    def request(self, body):
        payload = json.dumps(dict(body, token=self.state["token"])).encode()
        with socket.create_connection(("127.0.0.1", self.state["port"]), timeout=600) as client:
            client.sendall(struct.pack("<i", len(payload)) + payload)
            data = b""
            while True:
                chunk = client.recv(1 << 16)
                if not chunk:
                    break
                data += chunk
        return [json.loads(line) for line in data.decode().splitlines() if line]

    def compile(self, label):
        started = time.monotonic()
        responses = self.request({"arguments": compile_arguments("sources.txt", "out.hl")})
        wall = time.monotonic() - started
        messages = [response["message"] for response in responses if "message" in response]
        # The build's own report (phases, IR passes), kept for reading a change in the metrics.
        with open(os.path.join(os.path.dirname(self.log_path), "server-messages.log"), "a") as report:
            report.write(f"== {label}\n" + "\n".join(messages) + "\n")
        with open(self.log_path) as source:
            source.seek(self.offset)
            log = source.read()
            self.offset = source.tell()
        if [response.get("status") for response in responses if "status" in response] != [0]:
            sys.stderr.write("\n".join(messages)[-4000:] + "\n")
            raise SystemExit(f"perf-guard: the {label} build failed; server log: {self.log_path}")
        line = next(message for message in messages if message.startswith("driver allocation phases:"))
        fields = dict(field.split("=", 1) for field in line.split(":", 1)[1].split())
        build = {"label": label, "wall": wall,
                 "allocated_bytes": sum(int(value) for key, value in fields.items() if key.endswith("-bytes"))}
        reuse = next((message for message in messages if message.startswith("compiler phases (reused: ")), "")
        build["reuse"] = reuse[len("compiler phases (reused: "):].split(", linked")[0].split(") (ms)")[0]
        for row in log.splitlines():
            words = row.split()
            # `invalidation: N artifacts, retyped R`, then `  regenerated G: [...]`
            if row.startswith("invalidation: "):
                build["invalidated_artifacts"], build["retyped_functions"] = int(words[1]), int(words[4])
            elif row.startswith("  regenerated "):
                build["regenerated_functions"] = int(words[1].rstrip(":"))
            # `census write-done total mapped M MB resident R MB live L MB ...`
            elif len(words) > 3 and words[0] == "census" and words[2] == "total" and "live" in words:
                build["live_bytes"] = round(float(words[words.index("live") + 1]) * 1024 * 1024)
        missing = [name for name in ("retyped_functions", "regenerated_functions", "live_bytes") if name not in build]
        if missing:
            raise SystemExit(f"perf-guard: the {label} build reported no {', '.join(missing)}; server log: {self.log_path}")
        return build

    def stop(self):
        if self.process.poll() is None:
            try:
                self.request({"shutdown": True})
                self.process.wait(timeout=60)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        self.log.close()


def edit(tree, change, forward=True):
    path, old, new = change
    if not forward:
        old, new = new, old
    with open(os.path.join(tree, path)) as source:
        text = source.read()
    if text.count(old) != 1:
        raise SystemExit(f"perf-guard: {path} no longer holds the incremental edit's anchor {old!r} exactly once; "
                         "choose another in scripts/perf-guard.py and update the incremental baseline")
    with open(os.path.join(tree, path), "w") as target:
        target.write(text.replace(old, new))


def measure_incremental(hl, compiler, out, frozen):
    """Builds the compile server with `compiler` and drives it through the scripted builds; returns their metrics."""
    server = os.path.join(out, "compiler-server.hl")
    with open(os.path.join(out, "server-build.log"), "w") as log:
        status = subprocess.run(compile_command(hl, compiler, os.path.join(out, "sources.txt"), server, SERVER_ENTRY),
                                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
    if status != 0:
        raise SystemExit(f"perf-guard: building the compile server failed (exit {status}); log: {os.path.join(out, 'server-build.log')}")
    tree = os.path.join(out, "incremental")
    shutil.rmtree(tree, ignore_errors=True)
    os.makedirs(tree)
    for root in SOURCE_ROOTS:
        shutil.copytree(os.path.join(frozen, root), os.path.join(tree, root))
    shutil.copyfile(os.path.join(frozen, "sources.txt"), os.path.join(tree, "sources.txt"))
    open(os.path.join(out, "server-messages.log"), "w").close()
    session = CompileServer(hl, server, tree, os.path.join(out, "server.log"))
    try:
        builds = [session.compile("cold"), session.compile("first no-op"), session.compile("no-op")]
        for index in range(BODY_EDITS):
            edit(tree, BODY_EDIT, forward=index % 2 == 0)
            builds.append(session.compile("body edit" if index == 0 else f"body edit {index + 1}"))
        settled = builds[-1 - GROWTH_BUILDS:]
        edit(tree, SIGNATURE_EDIT)
        builds.append(session.compile("signature edit"))
        for index in range(LATE_BODY_EDITS):
            edit(tree, BODY_EDIT, forward=index % 2 == 0)
            builds.append(session.compile(f"late body edit {index + 1}"))
    finally:
        session.stop()
    for build in builds:
        print(f"perf-guard: {build['label']:16} wall {build['wall']:6.2f} s (not compared), allocated {build['allocated_bytes']:>11}, "
              f"retyped {build['retyped_functions']:>5}, regenerated {build['regenerated_functions']:>5}, "
              f"live {build['live_bytes'] / 1048576.0:7.1f} MB, reused: {build['reuse']}")
    named = {build["label"]: build for build in builds}
    metrics = {"cold_allocated_bytes": named["cold"]["allocated_bytes"]}
    for label, prefix in (("first no-op", "first_noop"), ("no-op", "noop"), ("body edit", "body_edit"),
                          ("signature edit", "signature_edit"), (f"late body edit {LATE_BODY_EDITS}", "late_body_edit")):
        for name in ("allocated_bytes", "retyped_functions", "invalidated_artifacts", "regenerated_functions"):
            metrics[f"{prefix}_{name}"] = named[label][name]
    metrics["server_live_bytes"] = settled[-1]["live_bytes"]
    metrics["server_live_growth_bytes"] = settled[-1]["live_bytes"] - settled[0]["live_bytes"]
    return metrics


def compare(path, metrics, update):
    """Compares `metrics` with the baseline at `path`, writing them into it on `update`; returns (failures, improvements)."""
    with open(path) as source:
        baseline = json.load(source)
    failures, improvements = [], []
    for name, entry in baseline["metrics"].items():
        if name not in metrics:
            continue
        value, expected = metrics[name], entry["value"]
        slack = entry["tolerance"] * abs(expected) if "tolerance" in entry else entry["tolerance_abs"]
        change = (value - expected) * 100.0 / expected if expected else 0.0
        verdict = "ok"
        if value > expected + slack:
            verdict = "REGRESSION"
            failures.append(name)
        elif value < expected - slack:
            verdict = "improved: update the baseline"
            improvements.append(name)
        print(f"  {name:34} {value:>16} baseline {expected:>16} {change:+7.2f}% (allowed +-{slack:.0f})  {verdict}")
        if update:
            entry["value"] = value
    if update:
        with open(path, "w") as target:
            json.dump(baseline, target, indent="\t")
            target.write("\n")
        print(f"perf-guard: wrote the measured values to {os.path.relpath(path, ROOT)}")
    return failures, improvements


def main(arguments):
    update = "--update" in arguments
    parts = ["self-compile", "incremental"]
    for argument in arguments:
        if argument.startswith("--only=") and argument[len("--only="):] in parts:
            parts = [argument[len("--only="):]]
        elif argument != "--update":
            raise SystemExit(__doc__)
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        print(f"perf-guard: skipped on {platform.system()} {platform.machine()}; the baseline is for Linux x86-64")
        return 0
    out = os.environ.get("HAXEON_SUITE_OUT") or os.path.join(ROOT, "out", "perf-guard")
    os.makedirs(out, exist_ok=True)
    hl = hashlink()
    tool = os.environ.get("HAXEON_COMPILER_HL") or run([os.path.join(ROOT, "scripts", "haxeon"), "dev", "tool-path", ENTRY]).strip()
    sources = os.path.join(out, "sources.txt")
    list_sources(ROOT, sources)
    frozen, frozen_sources = frozen_input(out)
    compiler = os.path.join(out, "compiler.hl")
    with open(os.path.join(out, "build.log"), "w") as log:
        status = subprocess.run(compile_command(hl, tool, sources, compiler), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
    if status != 0:
        raise SystemExit(f"perf-guard: building the compiler failed (exit {status}); log: {os.path.join(out, 'build.log')}")
    failures, improvements = [], []
    if "self-compile" in parts:
        metrics, skip = measure(hl, compiler, frozen_sources, os.path.join(out, "self-compile.hl"),
                                os.path.join(out, "self-compile.log"), frozen)
        metrics.update(measure_live(hl, compiler, frozen_sources, os.path.join(out, "self-compile-census.hl"),
                                    os.path.join(out, "self-compile-census.log"), frozen))
        cycles = metrics.get("main_thread_cycles")
        print(f"perf-guard: self-compile wall {metrics['wall_seconds']} s"
              + (f", main-thread cycles {cycles / 1e9:.2f}G" if cycles else "") + " (not compared)")
        if skip:
            print(f"perf-guard: instructions skipped: {skip}")
        found = compare(BASELINE, metrics, update)
        failures += found[0]
        improvements += found[1]
    if "incremental" in parts:
        started = time.monotonic()
        metrics = measure_incremental(hl, compiler, out, frozen)
        print(f"perf-guard: incremental builds wall {time.monotonic() - started:.1f} s (not compared)")
        found = compare(INCREMENTAL_BASELINE, metrics, update)
        failures += found[0]
        improvements += found[1]
    if update:
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
