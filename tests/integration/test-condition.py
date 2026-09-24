#!/usr/bin/env python3
"""Verify that the compiled Condition API reaches HashLink's native waits."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="haxeon-condition-") as directory:
        project = Path(directory)
        (project / "src").mkdir()
        (project / "haxeon.json").write_text(json.dumps({
            "version": 1, "package": {"name": "condition-check"},
            "entry": "Main", "sourceRoots": ["src"], "target": "host", "outputDir": "build"}))
        (project / "src/Main.hx").write_text('''import sys.thread.Condition;
import sys.thread.Thread;
class Main {
  static function main():Int {
    var condition = new Condition();
    condition.acquire();
    var started = Sys.time();
    condition.timedWait(0.05);
    var elapsed = Sys.time() - started;
    condition.release();
    if (elapsed < 0.04) throw "Timed wait returned early";
    var done = false;
    Thread.create(function() {
      condition.acquire();
      done = true;
      condition.broadcast();
      condition.release();
    });
    condition.acquire();
    while (!done) condition.wait();
    condition.release();
    return 0;
  }
}
''')
        bytecode = project / "main.hl"
        subprocess.run([str(ROOT / "scripts/haxeon"), "build", "--compiler-only",
                        "--project", str(project / "haxeon.json"), "--output", str(bytecode)],
                       check=True, capture_output=True, text=True)
        environment = os.environ.copy()
        environment["LD_LIBRARY_PATH"] = os.pathsep.join(
            [str(ROOT / "out"), str(ROOT / ".tools/hashlink"), environment.get("LD_LIBRARY_PATH", "")])
        subprocess.run([str(ROOT / ".tools/hashlink/hl"), str(bytecode)],
                       check=True, timeout=5, env=environment, capture_output=True, text=True)
    print("HashLink condition waits passed")


if __name__ == "__main__":
    main()
