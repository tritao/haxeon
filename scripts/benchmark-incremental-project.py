#!/usr/bin/env python3
"""Measure repeated body edits in an existing Haxeon project."""

import argparse
import pathlib
import re
import statistics
import subprocess


COMPILER = re.compile(r"compiler: ([0-9]+) ms, ([0-9]+) functions retyped")
EXECUTE = re.compile(r"execute: ([0-9.]+) ms")
PHASE = re.compile(r"([a-z-]+)=([0-9.]+)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--token-a", required=True)
    parser.add_argument("--token-b", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--max-compiler-ms", type=float)
    parser.add_argument("--max-execute-ms", type=float)
    parser.add_argument("--max-retyped", type=float)
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

    def build() -> str:
        completed = subprocess.run([
            str(repo / "scripts/haxeon"), "build", "--project", str(pathlib.Path(args.project).resolve()),
            f"--output={pathlib.Path(args.output).resolve()}", "--compiler-only", "--timings",
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
        if completed.returncode != 0:
            raise SystemExit(completed.stdout)
        return completed.stdout

    try:
        build()
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
            if compiler is None or execute is None or not phase_line:
                raise SystemExit("timing output was incomplete\n" + output)
            sample = {name: float(value) for name, value in PHASE.findall(phase_line)}
            sample.update(compiler=float(compiler.group(1)), retyped=float(compiler.group(2)), execute=float(execute.group(1)))
            samples.append(sample)
    finally:
        source.write_text(original, encoding="utf-8")
        build()

    keys = sorted(set.intersection(*(set(sample) for sample in samples)))
    print(f"median of {len(samples)} incremental edits (ms):")
    for key in keys:
        value = statistics.median(sample[key] for sample in samples)
        print(f"  {key}: {value:.2f}")
    medians = {key: statistics.median(sample[key] for sample in samples) for key in keys}
    failures = []
    for key, limit in (("compiler", args.max_compiler_ms), ("execute", args.max_execute_ms), ("retyped", args.max_retyped)):
        if limit is not None and medians[key] > limit:
            failures.append(f"{key} median {medians[key]:.2f} exceeds {limit:.2f}")
    if failures:
        raise SystemExit("incremental performance regression: " + "; ".join(failures))


if __name__ == "__main__":
    main()
