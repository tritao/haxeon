#!/usr/bin/env python3
"""The bytecode dumper must terminate on recursive structural function types."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    preset = os.environ.get("HAXEON_CMAKE_PRESET", "release")
    tool = Path(os.environ.get("HLDUMP", ROOT / "out/cmake" / preset / "hashlink/bin/hldump"))
    with tempfile.TemporaryDirectory(prefix="haxeon-hldump-") as directory:
        project = Path(directory)
        (project / "Main.hx").write_text('''typedef Node = {
  var next:Node;
  function visit(node:Node):Int;
}
class Main {
  static function main():Void {
    var node:Node = {next:null, visit:function(value:Node):Int return value == null ? 0 : 42};
    Sys.println(node.visit(node));
  }
}
''')
        bytecode = project / "recursive.hl"
        subprocess.run([str(ROOT / ".tools/haxe/haxe"), "-cp", str(project),
                        "-main", "Main", "-hl", str(bytecode)], check=True,
                       capture_output=True, text=True)
        for options in [[], ["--raw"], ["--debug"], ["--hashes"]]:
            command = [str(tool), *options, str(bytecode)]
            first = subprocess.run(command, check=True, capture_output=True, text=True, timeout=10)
            second = subprocess.run(command, check=True, capture_output=True, text=True, timeout=10)
            assert first.stdout == second.stdout, options
            if "--hashes" not in options:
                assert "recursive^" in first.stdout, options
    print("PASS: hldump prints recursive structural types deterministically")


if __name__ == "__main__":
    main()
