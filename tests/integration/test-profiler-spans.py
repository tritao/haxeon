#!/usr/bin/env python3
"""End-to-end named span capture, including UTF-8 names and stack correlation."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
HL = ROOT / ".tools/hashlink/hl"
PROFILER = ROOT / ".tools/hashlink/hlprof-live"


def run(*command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True, **kwargs)


def main():
    with tempfile.TemporaryDirectory(prefix="haxeon-profile-span-") as directory:
        root = Path(directory)
        (root / "src").mkdir()
        (root / "haxeon.json").write_text(json.dumps({
            "version": 1, "package": {"name": "profile-span-check"},
            "entry": "Main", "sourceRoots": ["src"], "target": "host", "outputDir": "build"}))
        (root / "src/Main.hx").write_text('''class Main {
  static function main():Int {
    haxeon.ProfileSpan.begin("check-é");
    var until = Sys.time() + 0.25;
    var count = 0;
    while (Sys.time() < until) count++;
    haxeon.ProfileSpan.end("check-é");
    until = Sys.time() + 0.25;
    while (Sys.time() < until) count++;
    return count == 0 ? 1 : 0;
  }
}
''')
        bytecode = root / "main.hl"
        run(ROOT / "scripts/haxeon", "build", "--compiler-only", "--project",
            root / "haxeon.json", "--output", bytecode)
        environment = os.environ.copy()
        environment["LD_LIBRARY_PATH"] = os.pathsep.join(
            [str(ROOT / "out"), str(HL.parent), environment.get("LD_LIBRARY_PATH", "")])
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        app = subprocess.Popen([str(HL), "--diagnostics", str(port), "--diagnostics-wait",
                                str(bytecode)], env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            capture = root / "capture.hlpc"
            run(PROFILER, "--connect-timeout", "10", "--rate", "50", "--interval", "20",
                "--output", capture, str(port), timeout=20)
            output, _ = app.communicate(timeout=10)
            if app.returncode:
                raise AssertionError(f"span fixture failed: {output}")
        finally:
            if app.poll() is None:
                app.terminate()
                app.wait(timeout=5)
        trace = root / "trace.json"
        run(PROFILER, "export", "--format", "perfetto", "--output", trace, capture)
        report = root / "report.json"
        run(sys.executable, ROOT / "scripts/hlprof-spans.py", "--min-ms", "0",
            "--output", report, trace)
        result = json.loads(report.read_text())
        assert result["spanCount"] == 1, result
        assert result["droppedRecords"] == 0, result
        assert not result["incompleteSpans"], result
        span = result["slowSpans"][0]
        assert span["name"] == "check-é" and span["sampleCount"] > 0, span
        print("profiler span capture passed")


if __name__ == "__main__":
    main()
