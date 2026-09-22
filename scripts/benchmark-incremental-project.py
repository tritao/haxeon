#!/usr/bin/env python3
"""Measure repeated body edits in an existing Haxeon project."""

import argparse
import os
import pathlib
import re
import signal
import socket
import statistics
import subprocess
import sys
import time


COMPILER = re.compile(r"compiler: ([0-9]+) ms, ([0-9]+) functions retyped")
EXECUTE = re.compile(r"execute: ([0-9.]+) ms")
PHASE = re.compile(r"([a-z-]+)=([0-9.]+(?:[eE][+-]?[0-9]+)?)")
ALLOCATIONS = re.compile(r"worker allocations: bytes=([0-9]+) count=([0-9]+) heap=([0-9]+)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--token-a", required=True)
    parser.add_argument("--token-b", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--profile-output", help="Capture the persistent compiler worker with hlprof-live")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--max-compiler-ms", type=float, default=2000.0)
    parser.add_argument("--max-execute-ms", type=float, default=2500.0)
    parser.add_argument("--max-retyped", type=float, default=4.0)
    args = parser.parse_args()
    if args.runs < 1:
        raise SystemExit("--runs must be positive")

    repo = pathlib.Path(__file__).resolve().parent.parent
    source = pathlib.Path(args.source).resolve()
    original = source.read_text(encoding="utf-8")
    if original.count(args.token_a) + original.count(args.token_b) != 1:
        raise SystemExit("source must contain exactly one benchmark token")
    current = args.token_a if args.token_a in original else args.token_b
    samples = []
    environment = os.environ.copy()
    profiler = None
    profile_path = pathlib.Path(args.profile_output).resolve() if args.profile_output else None
    if profile_path:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            profile_port = listener.getsockname()[1]
        environment["HAXEON_COMPILER_PROFILE_PORT"] = str(profile_port)

    def build() -> str:
        completed = subprocess.run([
            str(repo / "scripts/haxeon"), "build", "--project", str(pathlib.Path(args.project).resolve()),
            f"--output={pathlib.Path(args.output).resolve()}", "--compiler-only", "--timings",
        ], env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        if completed.returncode != 0:
            raise SystemExit(f"build exited {completed.returncode}:\n{completed.stdout}")
        return completed.stdout

    try:
        build()
        if profile_path:
            # A clean build can skip the compiler action and leave no worker to attach to.
            next_token = args.token_b if current == args.token_a else args.token_a
            source.write_text(original.replace(current, next_token, 1), encoding="utf-8")
            current = next_token
            build()
            profile_path.parent.mkdir(parents=True, exist_ok=True)
            profile_path.unlink(missing_ok=True)
            profiler = subprocess.Popen([
                str(repo / ".tools/hashlink/hlprof-live"), "--connect-timeout", "10", "--rate", "250",
                "--alloc-interval", "262144", "--interval", "500", "--output", str(profile_path),
                str(profile_port),
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            deadline = time.monotonic() + 15
            while (not profile_path.exists() or profile_path.stat().st_size < 24) and time.monotonic() < deadline:
                if profiler.poll() is not None:
                    raise SystemExit("hlprof-live could not attach: " + profiler.communicate()[0])
                time.sleep(0.05)
            if not profile_path.exists() or profile_path.stat().st_size < 24:
                raise SystemExit("hlprof-live did not start its capture")
        for _ in range(args.runs):
            next_token = args.token_b if current == args.token_a else args.token_a
            text = source.read_text(encoding="utf-8")
            if text.count(current) != 1:
                raise SystemExit("benchmark source changed unexpectedly")
            source.write_text(text.replace(current, next_token, 1), encoding="utf-8")
            current = next_token
            output = build()
            compiler = COMPILER.search(output)
            execute = EXECUTE.search(output)
            phase_line = next((line for line in output.splitlines() if line.startswith("compiler phases")), "")
            driver_line = next((line for line in output.splitlines() if line.startswith("driver phases")), "")
            if compiler is None or execute is None or not phase_line:
                raise SystemExit("timing output was incomplete\n" + output)
            sample = {name: float(value) for name, value in PHASE.findall(phase_line)}
            sample.update({"driver-" + name: float(value) for name, value in PHASE.findall(driver_line)})
            sample.update(compiler=float(compiler.group(1)), retyped=float(compiler.group(2)), execute=float(execute.group(1)))
            sample["command-overhead"] = sample["execute"] - sample["compiler"]
            allocations = ALLOCATIONS.search(output)
            if allocations is not None:
                sample.update(allocated_bytes=float(allocations.group(1)), allocations=float(allocations.group(2)), heap_bytes=float(allocations.group(3)))
            samples.append(sample)
    finally:
        profiler_error = None
        if profiler is not None:
            if profiler.poll() is None:
                profiler.send_signal(signal.SIGINT)
            try:
                profiler_output = profiler.communicate(timeout=30)[0]
            except subprocess.TimeoutExpired:
                profiler.kill()
                profiler_output = profiler.communicate()[0]
                profiler_error = "hlprof-live did not stop within 30 seconds"
            if profiler.returncode != 0 and profiler_error is None:
                profiler_error = "hlprof-live did not finalize its capture:\n" + profiler_output
        source.write_text(original, encoding="utf-8")
        build()
        if profiler_error and sys.exc_info()[0] is None:
            raise SystemExit(profiler_error)

    if profile_path:
        report = subprocess.run([str(repo / ".tools/hashlink/hlprof-live"), "report", "--top", "20", str(profile_path)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if report.returncode != 0 or not re.search(r"samples=([1-9][0-9]*)", report.stdout):
            raise SystemExit("Profile capture has no readable samples:\n" + report.stdout)
        print(f"Profile capture: {profile_path}")
        print(report.stdout)

    keys = sorted(set.intersection(*(set(sample) for sample in samples)))
    print(f"median of {len(samples)} incremental edits (ms):")
    for key in keys:
        value = statistics.median(sample[key] for sample in samples)
        print(f"  {key}: {value:.2f}")
    medians = {key: statistics.median(sample[key] for sample in samples) for key in keys}
    failures = []
    for key, limit in (("compiler", None if profile_path else args.max_compiler_ms),
                       ("execute", None if profile_path else args.max_execute_ms), ("retyped", args.max_retyped)):
        if limit is not None and medians[key] > limit:
            failures.append(f"{key} median {medians[key]:.2f} exceeds {limit:.2f}")
    if failures:
        raise SystemExit("incremental performance regression: " + "; ".join(failures))


if __name__ == "__main__":
    main()
