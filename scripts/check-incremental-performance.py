#!/usr/bin/env python3
"""Smoke-test persistent compiler performance with a generated project."""

import argparse
import json
import os
import pathlib
import re
import socket
import struct
import subprocess
import tempfile


COMPILER = re.compile(r"compiler: ([0-9]+) ms, ([0-9]+) functions retyped")


def stop_workers(states: pathlib.Path) -> None:
    for state in states.glob("*.json"):
        try:
            value = json.loads(state.read_text(encoding="utf-8"))
            with socket.create_connection(("127.0.0.1", value["port"]), timeout=2) as client:
                body = json.dumps({"token": value["token"], "shutdown": True}).encode()
                client.sendall(struct.pack("<i", len(body)) + body)
                client.recv(1024)
        except (OSError, ValueError, KeyError):
            pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--modules", type=int, default=250)
    parser.add_argument("--max-edit-ms", type=int, default=5000)
    parser.add_argument("--max-edit-ratio", type=float, default=0.70)
    parser.add_argument("--max-retyped", type=int, default=4)
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    command = repo / "scripts/haxeon"
    environment = os.environ.copy()
    environment.pop("HAXEON_COMPILER_SERVER", None)

    with tempfile.TemporaryDirectory(prefix="haxeon-incremental-performance-") as temporary:
        root = pathlib.Path(temporary)
        source = root / "src/bench"
        source.mkdir(parents=True)
        manifest = root / "haxeon.json"
        manifest.write_text(json.dumps({
            "version": 1,
            "package": {"name": "benchmark"},
            "entry": "bench.Main",
            "sourceRoots": ["src"],
            "target": "host",
            "outputDir": "build",
        }), encoding="utf-8")
        for index in range(args.modules):
            (source / f"Module{index}.hx").write_text(
                f"package bench; class Module{index} {{ public static function value():Int return {index}; }}\n",
                encoding="utf-8",
            )
        calls = " + ".join(f"Module{index}.value()" for index in range(args.modules))
        main_source = source / "Main.hx"
        main_source.write_text(f"package bench; class Main {{ public static function main():Int return 0 + {calls}; }}\n", encoding="utf-8")

        def build() -> tuple[int, int, str]:
            completed = subprocess.run(
                [str(command), "build", "--project", str(manifest), "--compiler-only", "--timings"],
                cwd=root,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=120,
            )
            if completed.returncode != 0:
                raise SystemExit(completed.stdout)
            match = COMPILER.search(completed.stdout)
            if match is None:
                raise SystemExit("compiler timing was missing from build output\n" + completed.stdout)
            return int(match.group(1)), int(match.group(2)), completed.stdout

        try:
            cold_ms, _, _ = build()
            main_source.write_text(main_source.read_text(encoding="utf-8").replace("return 0 +", "return 1 +"), encoding="utf-8")
            edit_ms, retyped, output = build()
            if "reusing compiler session" not in output:
                raise SystemExit("incremental build did not reuse its compiler worker")
            failures = []
            if edit_ms > args.max_edit_ms:
                failures.append(f"edit took {edit_ms} ms (limit {args.max_edit_ms} ms)")
            if cold_ms > 0 and edit_ms / cold_ms > args.max_edit_ratio:
                failures.append(f"edit/cold ratio was {edit_ms / cold_ms:.2f} (limit {args.max_edit_ratio:.2f})")
            if retyped > args.max_retyped:
                failures.append(f"edit retyped {retyped} functions (limit {args.max_retyped})")
            if failures:
                raise SystemExit("incremental performance regression: " + "; ".join(failures))
            print(f"PASS: cold={cold_ms} ms edit={edit_ms} ms ratio={edit_ms / cold_ms:.2f} retyped={retyped}")
        finally:
            stop_workers(root / "build/.haxeon/compiler")


if __name__ == "__main__":
    main()
