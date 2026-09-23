#!/usr/bin/env python3
"""Inspect a HashLink heap dump with the matching bytecode and vendored hlmem."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
HAXE = ROOT / ".tools/haxe/haxe"
HL = ROOT / ".tools/hashlink/hl"
HLMEM = ROOT / "vendor/hashlink/other/haxelib"
FORMAT = ROOT / "vendor/format"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bytecode", type=Path, help="exact .hl file used by the captured process")
    parser.add_argument("dump", type=Path, help="HashLink gc_dump_memory output")
    parser.add_argument("--report", type=Path, help="text report path (default: beside dump)")
    args = parser.parse_args()
    bytecode = args.bytecode.resolve()
    dump = args.dump.resolve()
    report = (args.report or dump.with_name("heap-report.txt")).resolve()
    for path in (bytecode, dump, HAXE, HL, HLMEM / "hlmem/Main.hx", FORMAT / "format/hl/Reader.hx"):
        if not path.is_file():
            parser.error(f"required heap inspection input is missing: {path}")
    with tempfile.TemporaryDirectory(prefix="haxeon-hlmem-") as scratch:
        temp = Path(scratch)
        analyzer = temp / "hlmem.hl"
        subprocess.run([str(HAXE), "-cp", str(HLMEM), "-cp", str(FORMAT),
                        "-main", "hlmem.Main", "-hl", str(analyzer)],
                       cwd=ROOT, check=True)
        result = subprocess.run([str(HL), str(analyzer), str(bytecode), str(dump),
                                 "--no-color", "--args", "stats", "types", "quit"],
                                cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(result.stdout)
    if result.returncode:
        print(f"heap inspection failed; see {report}", file=sys.stderr)
        return result.returncode
    for line in result.stdout.splitlines():
        if "live blocks" in line or "unresolved type" in line:
            print(line)
    print(f"report={report}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"heap inspection failed: {error}", file=sys.stderr)
        sys.exit(1)
