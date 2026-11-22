#!/usr/bin/env python3
"""Guards the cost of the compiler against tests/perf/*-baseline.json: compiling a frozen copy of its sources once and in a
compile server, and building a small project from a cold start.

    scripts/perf-guard.py                          measure, compare, fail on a regression beyond a metric's tolerance
    scripts/perf-guard.py --update                 measure and write the measured values into the baselines (tolerances are kept)
    scripts/perf-guard.py --only=incremental       only one part (self-compile, incremental or small-project), with or
                                                   without --update

Every metric fails the run beyond its tolerance, but they do not weigh the same. In order, the compiler is optimized for:
  1. edit latency in the compile server: main-thread instructions of a body edit and of a signature edit
  2. startup, which dominates a small project's build: instructions of a cold small-project build and check
  3. the compile server's live data, weighted above the one-shot compile's peak
These are the primary metrics: marked `*` where compared, and summed up in the first line of the summary the run ends with.
The cold self-compile (instructions, wall, peak RSS, allocation, live data) and the incremental part's allocation and function
counts are regression guards: they keep a change from making the rest worse, and are not themselves the target.

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

A second session of that server, without the census and the invalidation reports, measures edit latency: main-thread
instructions:u (cycles:u reported) of the body edit (the median of three) and of the signature edit, from perf --per-thread
attached to the server around each build. The server compiles on a thread of its own, which inherits the main thread's
counters, so the main thread's row holds the build's work. Skipped where perf is not available.

The small-project part (tests/perf/small-project-baseline.json) runs the CLI built from the checkout (`haxeon build` and
`haxeon check` of tests/perf/small-project) as a user does, from no compile server running: the CLI starts the project's
server and asks it to compile. It reads instructions:u of every process the command starts, counted until the server leaves
(perf cannot follow a detached server per thread), and the bytes the server allocated for the request (its worker
allocations); wall of the CLI is reported, never compared. It runs in two modes, each with metrics of its own, so the result
never depends on what happens to be built:
  vm    always: haxeon-aot set aside for the run, so the CLI and the server are the VM running their bytecode (the server's
        compiled once into the guard's session directory)
  aot   when the CLI and compiler built ahead of time (haxeon-aot, `haxeon dev aot`) is current: it runs the CLI and serves the
        compile. Skipped, and passing, when it is not built or stale.

Measures on Linux x86-64 only, where the baseline was taken; elsewhere it says so and passes. A metric beyond its tolerance
below the baseline passes and asks for the baseline to be updated, so gains are locked in.
"""
import json
import os
import platform
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "tests", "perf", "self-compile-baseline.json")
INCREMENTAL_BASELINE = os.path.join(ROOT, "tests", "perf", "incremental-baseline.json")
SMALL_PROJECT_BASELINE = os.path.join(ROOT, "tests", "perf", "small-project-baseline.json")
SMALL_PROJECT = os.path.join(ROOT, "tests", "perf", "small-project")
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


def performance_cores():
    """The command prefix and perf event prefix that keep a measured process on one core type and count its counter.

    On a hybrid CPU each core type has its own counter, multiplexed and extrapolated when the thread moves between them: keep the
    process on the performance cores and count theirs."""
    hybrid = "/sys/bus/event_source/devices/cpu_core/cpus"
    if os.path.exists(hybrid):
        with open(hybrid) as source:
            return ["taskset", "-c", source.read().strip()], "cpu_core/"
    return [], ""


def measure(hl, compiler, sources, output, log_path, cwd):
    """Runs one compile in `cwd`; returns its metrics."""
    env = dict(os.environ, HL_GC_MARK_SERIAL="1")
    skip = perf_unavailable()
    command, prefix = compile_command(hl, compiler, sources, output), ""
    if skip is None:
        pin, prefix = performance_cores()
        command = pin + command
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


def server_request(state, body):
    """Sends one request to the compile server that `state` (its state file's contents) describes; returns its responses."""
    payload = json.dumps(dict(body, token=state["token"])).encode()
    with socket.create_connection(("127.0.0.1", state["port"]), timeout=600) as client:
        client.sendall(struct.pack("<i", len(payload)) + payload)
        data = b""
        while True:
            chunk = client.recv(1 << 16)
            if not chunk:
                break
            data += chunk
    return [json.loads(line) for line in data.decode().splitlines() if line]


class CompileServer:
    """A compile server on a copy of the sources, driven over its protocol (compiler.tools.CompilerServerProtocol)."""

    def __init__(self, hl, server, tree, log_path, reports=True, pin=()):
        self.tree, self.log_path, self.reports = tree, log_path, reports
        state = os.path.join(tree, "server.json")
        env = dict(os.environ, HL_GC_MARK_SERIAL="1", HAXEON_COMPILER_IDLE_SECONDS="900")
        if reports:
            # The census at the end of each build (`write-done`) collects first and reports the live data per size class only;
            # the explanation of each build's invalidation names what it retyped and regenerated.
            env.update(HAXEON_PEAK_CENSUS="write-done", HL_GC_CENSUS_PAGES_ONLY="1", HAXEON_EXPLAIN_INVALIDATION="1")
        self.log = open(log_path, "w")
        self.offset = 0
        self.process = subprocess.Popen(list(pin) + [hl, server, state], cwd=tree, env=env, stdin=subprocess.DEVNULL,
                                        stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 60
        while not os.path.exists(state):
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise SystemExit(f"perf-guard: the compile server did not start; log: {log_path}")
            time.sleep(0.05)
        with open(state) as source:
            self.state = json.load(source)

    def request(self, body):
        return server_request(self.state, body)

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
        if missing and self.reports:
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
    tree = copy_frozen(frozen, os.path.join(out, "incremental"))
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
    skip = perf_unavailable()
    if skip is None:
        metrics.update(measure_edit_latency(hl, server, frozen, out))
    else:
        print(f"perf-guard: edit latency skipped: {skip}")
    return metrics


def copy_frozen(frozen, tree):
    """A fresh copy of the frozen input at `tree`, for a compile server to edit."""
    shutil.rmtree(tree, ignore_errors=True)
    os.makedirs(tree)
    for root in SOURCE_ROOTS:
        shutil.copytree(os.path.join(frozen, root), os.path.join(tree, root))
    shutil.copyfile(os.path.join(frozen, "sources.txt"), os.path.join(tree, "sources.txt"))
    return tree


class ThreadCounter:
    """perf stat --per-thread attached to a running process, counting only while enabled over its control fifos.

    A thread the process starts while counted (the server's compile thread, the threads it starts in turn) inherits its
    creator's counters, so the main thread's row holds the work of every thread it started."""

    def __init__(self, pid, prefix, directory):
        self.pid = pid
        self.events = {prefix + "instructions/u": "instructions", prefix + "cycles/u": "cycles"}
        self.control, self.ack = os.path.join(directory, "perf-control.fifo"), os.path.join(directory, "perf-ack.fifo")
        for path in (self.control, self.ack):
            if os.path.exists(path):
                os.remove(path)
            os.mkfifo(path)
        self.process = subprocess.Popen(["perf", "stat", "--per-thread", "-x,", "-e", ",".join(self.events), "-p", str(pid),
                                         "--delay=-1", f"--control=fifo:{self.control},{self.ack}"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        # Opened for reading and writing, as perf opens them, so neither side waits for the other to open.
        self.control_fd, self.ack_fd = os.open(self.control, os.O_RDWR), os.open(self.ack, os.O_RDWR)

    def command(self, word):
        os.write(self.control_fd, (word + "\n").encode())
        if not select.select([self.ack_fd], [], [], 60)[0] or not os.read(self.ack_fd, 64).startswith(b"ack"):
            self.process.kill()
            raise SystemExit(f"perf-guard: perf did not acknowledge {word!r}: " + self.process.communicate()[1][:200])

    def counts(self):
        """Stops counting; returns the main thread's counts by event name."""
        self.command("disable")
        self.process.send_signal(signal.SIGINT)
        _, errors = self.process.communicate()
        os.close(self.control_fd)
        os.close(self.ack_fd)
        rows = [row.split(",") for row in errors.splitlines()]
        counts = {}
        for event, name in self.events.items():
            found = [int(row[1]) for row in rows
                     if len(row) > 3 and row[0].endswith(f"-{self.pid}") and row[1].isdigit() and row[3] == event]
            if found:
                counts[name] = sum(found)
        if "instructions" not in counts:
            raise SystemExit("perf-guard: perf counted nothing: " + errors.strip().replace("\n", " ")[:200])
        return counts


# The edit-latency session measures each body edit this many times (made and taken back) and keeps the median.
LATENCY_BODY_EDITS = 3


def measure_edit_latency(hl, server, frozen, out):
    """Main-thread instructions of a body edit and of the signature edit, as a user's edit pays them: in a session of their own,
    without the incremental part's census and invalidation reports, whose work would count in them."""
    tree = copy_frozen(frozen, os.path.join(out, "edit-latency"))
    pin, prefix = performance_cores()
    session = CompileServer(hl, server, tree, os.path.join(out, "edit-latency-server.log"), reports=False, pin=pin)

    def counted(label):
        counter = ThreadCounter(session.process.pid, prefix, out)
        counter.command("enable")
        build = session.compile(label)
        build.update(counter.counts())
        return build

    try:
        session.compile("latency cold")
        session.compile("latency no-op")
        body = []
        for index in range(LATENCY_BODY_EDITS):
            edit(tree, BODY_EDIT, forward=index % 2 == 0)
            body.append(counted(f"latency body edit {index + 1}"))
        if LATENCY_BODY_EDITS % 2:
            edit(tree, BODY_EDIT, forward=False)
            session.compile("latency body edit undone")
        edit(tree, SIGNATURE_EDIT)
        signature = counted("latency signature edit")
    finally:
        session.stop()
    for build in body + [signature]:
        print(f"perf-guard: {build['label']:24} wall {build['wall']:6.2f} s, cycles {build.get('cycles', 0) / 1e9:6.2f}G "
              f"(not compared), instructions {build['instructions'] / 1e9:6.2f}G")
    return {"body_edit_instructions": sorted(build["instructions"] for build in body)[len(body) // 2],
            "signature_edit_instructions": signature["instructions"]}


# The small project's builds run the CLI as a user does, with the compile servers it starts kept in a session directory of the
# guard's. The command runs in a shell that waits for the server to leave after the build (HAXEON_COMPILER_IDLE_SECONDS) so that
# perf, counting the shell and everything it starts, counts the server's work too, and that records the CLI's own wall time and
# which program served the compile. perf puts its own directory on PATH, which the CLI's choice of server program depends on, so
# the shell puts the user's back.
SMALL_PROJECT_SHELL = """export PATH="$PERF_GUARD_PATH"
started=$(date +%s%N)
"$@" > "$PERF_GUARD_LOG" 2>&1
status=$?
echo $(( $(date +%s%N) - started )) > "$PERF_GUARD_WALL"
for state in "$HAXEON_COMPILER_SESSION_DIR"/*.json; do
    pid=$(sed -n 's/.*"pid":\\([0-9]*\\).*/\\1/p' "$state" 2>/dev/null)
    if [ -n "$pid" ]; then
        readlink "/proc/$pid/exe" > "$PERF_GUARD_SERVER"
        tail --pid="$pid" -s 0.05 -f /dev/null
    fi
done
exit $status
"""


def stop_workers(session):
    """Shuts down the compile servers the CLI started with `session` as its session directory, and waits for them to leave."""
    for name in sorted(os.listdir(session)):
        path = os.path.join(session, name)
        if not name.endswith(".json"):
            continue
        try:
            with open(path) as source:
                state = json.load(source)
            server_request(state, {"shutdown": True})
        except (OSError, ValueError, KeyError):
            continue
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                os.kill(state["pid"], 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            os.kill(state["pid"], signal.SIGKILL)
        if os.path.exists(path):
            os.remove(path)


# Where haxeon-aot waits while the vm mode runs; a guard stopped mid-run leaves it there, and the next run puts it back.
AOT_ASIDE_SUFFIX = ".perf-guard-aside"


def aot_current():
    """Whether the checkout's haxeon-aot is current, as `haxeon doctor` reports it."""
    report = subprocess.run([os.path.join(ROOT, "scripts", "haxeon"), "doctor"], cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True).stdout
    return any(line.startswith("ok: CLI and compiler built ahead of time") for line in report.splitlines())


def measure_small_project(hl, out):
    """Both modes of the small-project part (the docstring at the top): vm always, aot when haxeon-aot is current."""
    executable = os.path.join(os.path.dirname(hl), "haxeon-aot")
    if os.path.exists(executable + AOT_ASIDE_SUFFIX) and not os.path.exists(executable):
        os.rename(executable + AOT_ASIDE_SUFFIX, executable)
    metrics = {}
    aside = os.path.exists(executable)
    if aside:
        os.rename(executable, executable + AOT_ASIDE_SUFFIX)
    try:
        metrics.update(measure_small_project_mode(out, "vm", "hl"))
    finally:
        if aside:
            os.rename(executable + AOT_ASIDE_SUFFIX, executable)
    if aot_current():
        metrics.update(measure_small_project_mode(out, "aot", "haxeon-aot"))
    else:
        print("perf-guard: small project aot: skipped (haxeon-aot not built, or stale: build it with haxeon dev aot)")
    return metrics


def measure_small_project_mode(out, mode, expected_server):
    """A cold `haxeon build` and `haxeon check` of tests/perf/small-project, as a user starts one: the CLI, which starts the
    project's compile server, and the compile; returns their metrics, named after `mode`. The server must be `expected_server`:
    the mode measures that program or nothing."""
    work = os.path.join(out, "small-project", mode)
    # Kept between runs, as a user's is: it holds the server program the CLI builds once for the checkout's compiler.
    session = os.path.join(work, "session")
    project = os.path.join(work, "project")
    os.makedirs(session, exist_ok=True)
    shutil.rmtree(project, ignore_errors=True)
    shutil.copytree(SMALL_PROJECT, project)
    haxeon = os.path.join(ROOT, "scripts", "haxeon")
    env = dict(os.environ, HAXEON_COMPILER_SESSION_DIR=session, HL_GC_MARK_SERIAL="1", HAXEON_COMPILER_IDLE_SECONDS="1",
               PERF_GUARD_LOG=os.path.join(work, "command.log"), PERF_GUARD_WALL=os.path.join(work, "wall"),
               PERF_GUARD_SERVER=os.path.join(work, "server"), PERF_GUARD_PATH=os.environ.get("PATH", ""))
    stop_workers(session)
    # Unmeasured: builds the server program when the session has none for this compiler yet, and warms the file cache.
    with open(os.path.join(work, "warm-up.log"), "w") as log:
        status = subprocess.run([haxeon, "build", "--project", "haxeon.json"], cwd=project, env=env, stdout=log,
                                stderr=subprocess.STDOUT).returncode
    stop_workers(session)
    if status != 0:
        raise SystemExit(f"perf-guard: the small project's warm-up build failed (exit {status}); log: {log.name}")
    # The CLI is current now; the measured commands skip bringing it up to date.
    env["HAXEON_NATIVE_READY"] = "1"
    skip = perf_unavailable()
    pin, prefix = performance_cores() if skip is None else ([], "")
    events = {prefix + "instructions/u": "instructions", prefix + "cycles/u": "cycles"}
    metrics = {}
    for command in ("build", "check"):
        shutil.rmtree(os.path.join(project, "build"), ignore_errors=True)
        shell = pin + ["sh", "-c", SMALL_PROJECT_SHELL, "sh", haxeon, command, "--project", "haxeon.json", "-v", "detailed"]
        if skip is None:
            shell = ["perf", "stat", "-x,", "-e", ",".join(events), "--"] + shell
        process = subprocess.run(shell, cwd=project, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        stop_workers(session)
        with open(env["PERF_GUARD_LOG"]) as source:
            log = source.read()
        if process.returncode != 0:
            sys.stderr.write(log[-4000:] + process.stderr[-2000:])
            raise SystemExit(f"perf-guard: the small project's {command} failed (exit {process.returncode}); "
                             f"log: {env['PERF_GUARD_LOG']}")
        # `worker allocations: bytes=B count=C heap=H`, what the server allocated for the request, on the VM and built ahead of
        # time alike.
        line = next((line for line in log.splitlines() if line.startswith("worker allocations: ")), None)
        if line is None:
            raise SystemExit(f"perf-guard: the small project's {mode} {command} reported no worker allocations; "
                             f"log: {env['PERF_GUARD_LOG']}")
        fields = dict(field.split("=", 1) for field in line.split(":", 1)[1].split())
        metrics[f"{mode}_{command}_allocated_bytes"] = int(fields["bytes"])
        counts = {}
        for row in (row.split(",") for row in process.stderr.splitlines()):
            if len(row) > 2 and row[0].isdigit() and row[2] in events:
                counts[events[row[2]]] = int(row[0])
        if "instructions" in counts:
            metrics[f"{mode}_{command}_instructions"] = counts["instructions"]
        with open(env["PERF_GUARD_WALL"]) as source:
            wall = int(source.read()) / 1e9
        with open(env["PERF_GUARD_SERVER"]) as source:
            server = os.path.basename(source.read().strip())
        if server != expected_server:
            raise SystemExit(f"perf-guard: the small project's {mode} {command} was served by {server or 'nothing'}, "
                             f"not {expected_server}")
        print(f"perf-guard: small project {mode:3} cold {command:5} wall {wall:5.2f} s"
              + (f", cycles {counts['cycles'] / 1e9:.2f}G" if "cycles" in counts else "") + " (not compared), "
              + (f"instructions {counts['instructions'] / 1e9:.2f}G, " if "instructions" in counts else "")
              + f"served by {server}")
    if skip:
        print(f"perf-guard: small project instructions skipped: {skip}")
    return metrics


# The metrics the compiler is optimized for, in the order of the priorities, and those that only guard against regressions:
# each is (baseline, metric, label) and appears in the summary the run ends with. A primary metric's row is marked with `*`.
PRIMARY = [(INCREMENTAL_BASELINE, "body_edit_instructions", "body edit"),
           (INCREMENTAL_BASELINE, "signature_edit_instructions", "signature edit"),
           (SMALL_PROJECT_BASELINE, "vm_build_instructions", "small-project cold build on the VM"),
           (SMALL_PROJECT_BASELINE, "vm_check_instructions", "check on the VM"),
           (SMALL_PROJECT_BASELINE, "aot_build_instructions", "cold build ahead of time"),
           (SMALL_PROJECT_BASELINE, "aot_check_instructions", "check ahead of time"),
           (INCREMENTAL_BASELINE, "server_live_bytes", "server live")]
REGRESSION_GUARDS = [(BASELINE, "main_thread_instructions", "self-compile"), (BASELINE, "peak_rss_bytes", "self-compile peak")]


def summary(heading, metrics, compared):
    """One line of the metrics in `metrics` that were measured, with their change from the baseline."""
    parts = []
    for path, name, label in metrics:
        if (path, name) in compared:
            value, change = compared[(path, name)]
            amount = f"{value / 1e9:.2f}G instructions" if name.endswith("instructions") else f"{value / 1048576.0:.0f} MB"
            parts.append(f"{label} {amount} ({change:+.1f}%)")
    if parts:
        print(f"perf-guard: {heading}: " + ", ".join(parts))


def compare(path, metrics, update, compared):
    """Compares `metrics` with the baseline at `path`, writing them into it on `update` and each compared value and its change
    into `compared`, by (path, name); returns (failures, improvements)."""
    with open(path) as source:
        baseline = json.load(source)
    failures, improvements = [], []
    primary = {name for baseline_path, name, _ in PRIMARY if baseline_path == path}
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
        compared[(path, name)] = (value, change)
        print(f"{'*' if name in primary else ' '} {name:34} {value:>16} baseline {expected:>16} {change:+7.2f}% "
              f"(allowed +-{slack:.0f})  {verdict}")
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
    parts = ["self-compile", "incremental", "small-project"]
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
    failures, improvements, compared = [], [], {}
    if "self-compile" in parts or "incremental" in parts:
        tool = os.environ.get("HAXEON_COMPILER_HL") or run([os.path.join(ROOT, "scripts", "haxeon"), "dev", "tool-path",
                                                            ENTRY]).strip()
        sources = os.path.join(out, "sources.txt")
        list_sources(ROOT, sources)
        frozen, frozen_sources = frozen_input(out)
        compiler = os.path.join(out, "compiler.hl")
        with open(os.path.join(out, "build.log"), "w") as log:
            status = subprocess.run(compile_command(hl, tool, sources, compiler), cwd=ROOT, stdout=log,
                                    stderr=subprocess.STDOUT).returncode
        if status != 0:
            raise SystemExit(f"perf-guard: building the compiler failed (exit {status}); log: {os.path.join(out, 'build.log')}")
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
        found = compare(BASELINE, metrics, update, compared)
        failures += found[0]
        improvements += found[1]
    if "incremental" in parts:
        started = time.monotonic()
        metrics = measure_incremental(hl, compiler, out, frozen)
        print(f"perf-guard: incremental builds wall {time.monotonic() - started:.1f} s (not compared)")
        found = compare(INCREMENTAL_BASELINE, metrics, update, compared)
        failures += found[0]
        improvements += found[1]
    if "small-project" in parts:
        found = compare(SMALL_PROJECT_BASELINE, measure_small_project(hl, out), update, compared)
        failures += found[0]
        improvements += found[1]
    summary("primary", PRIMARY, compared)
    summary("regression guards", REGRESSION_GUARDS, compared)
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
