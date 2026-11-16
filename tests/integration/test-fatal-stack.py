#!/usr/bin/env python3
"""Real native faults retain their signal and report Haxe callers on main/worker stacks."""
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import tempfile
import select

ROOT = Path(__file__).resolve().parents[2]
HASHLINK_DIR = Path(subprocess.check_output([str(ROOT / "scripts/hashlink-path.sh")], text=True).strip())
# A native library's hl_* symbols resolve against the VM that loads it; macOS's linker needs to be told so, as CMakeLists.txt
# does for the runtime library.
HOST_SYMBOLS = ["-Wl,-undefined,dynamic_lookup"] if sys.platform == "darwin" else []


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix="haxeon-fatal-stack-") as directory:
        project = Path(directory)
        bytecode = project / "fatal.hl"
        subprocess.run([str(ROOT / ".tools/haxe/haxe"), "-cp", "src", "-cp", "lib/haxeon-io", "--run",
                        "compiler.tools.HaxeonCompiler", "--entry=FatalStack",
                        "--root=tests/fixtures", "--define=haxeon-inline=0", "--output=" + str(bytecode),
                        "tests/fixtures/FatalStack.hx"], cwd=ROOT, check=True,
                       capture_output=True, text=True)
        subprocess.run([os.environ.get("CC", "cc"), "-shared", "-fPIC",
                        "-fno-omit-frame-pointer", "-I", str(ROOT / "vendor/hashlink/src"),
                        str(ROOT / "vendor/hashlink/other/tests/crash_test.c"),
                        "-o", str(project / "crash_test.hdll")] + HOST_SYMBOLS, check=True)
        environment = os.environ.copy()
        for variable in ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]:
            environment[variable] = os.pathsep.join([
                str(project), str(ROOT / "out"), str(HASHLINK_DIR),
                environment.get(variable, "")])
        command = [str(HASHLINK_DIR / "hl"), str(bytecode)]
        for mode in ["main", "worker", "overflow"]:
            result = subprocess.run(command + [mode], env=environment,
                                    capture_output=True, text=True, timeout=10)
            assert result.returncode == -signal.SIGSEGV, result
            assert "HashLink fatal error: SIGSEGV" in result.stderr, result
            if mode != "overflow":
                assert re.search(r"resolveTarget\(FatalStack.hx:\d+\)", result.stderr), result
                assert re.search(r"runPlanner\(FatalStack.hx:\d+\)", result.stderr), result
            assert "unexpected catch" not in result.stdout, result
        # External signals stay fatal and are never mistaken for a language null access.
        for number in [signal.SIGSEGV, signal.SIGABRT]:
            process = subprocess.Popen(command + ["wait"], env=environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert select.select([process.stdout], [], [], 5)[0], "VM did not become ready"
                assert process.stdout.readline().strip() == "ready"
                process.send_signal(number)
                stdout, stderr = process.communicate(timeout=5)
                assert process.returncode == -number, (process.returncode, stdout, stderr)
                assert "sent externally" in stderr, stderr
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
    print("PASS: fatal main/worker source stacks, worker overflow, and external signal semantics")


if __name__ == "__main__":
    main()
