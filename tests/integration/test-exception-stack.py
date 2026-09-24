#!/usr/bin/env python3
"""Verify caught Haxe exceptions retain HashLink source frames."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="haxeon-exception-stack-") as directory:
        project = Path(directory)
        (project / "src").mkdir()
        (project / "haxeon.json").write_text(json.dumps({
            "version": 1, "package": {"name": "exception-stack-check"},
            "entry": "Main", "sourceRoots": ["src"], "target": "host", "outputDir": "build"}))
        (project / "src/Main.hx").write_text('''import haxe.CallStack;
class Main {
  static function fail():Void throw "boom";
  static function main():Int {
    try { fail(); }
    catch (error:Dynamic) {
      var stack = CallStack.toString(CallStack.exceptionStack());
      Sys.println(stack);
      return stack.indexOf("Main.fail") >= 0 && stack.indexOf("Main.hx:") >= 0 ? 0 : 1;
    }
  }
}
''')
        bytecode = project / "main.hl"
        subprocess.run([str(ROOT / "scripts/haxeon"), "build", "--compiler-only",
                        "--project", str(project / "haxeon.json"), "--output", str(bytecode)],
                       check=True, capture_output=True, text=True)
        environment = os.environ.copy()
        environment["LD_LIBRARY_PATH"] = os.pathsep.join(
            [str(ROOT / "out"), str(ROOT / ".tools/hashlink"),
             environment.get("LD_LIBRARY_PATH", "")])
        subprocess.run([str(ROOT / ".tools/hashlink/hl"), str(bytecode)],
                       check=True, timeout=5, env=environment, capture_output=True, text=True)
    print("HashLink exception stacks passed")


if __name__ == "__main__":
    main()
