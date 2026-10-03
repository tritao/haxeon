#!/usr/bin/env python3
"""Check stdout retention and ordering at VM exit and blocking boundaries."""
import os
import json
from pathlib import Path
import resource
import pty
import select
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    environment = os.environ.copy()
    environment.pop("HL_STDOUT_FLUSH", None)
    environment["LD_LIBRARY_PATH"] = os.pathsep.join([
        str(ROOT / "out"), str(ROOT / ".tools/hashlink"),
        environment.get("LD_LIBRARY_PATH", "")])
    with tempfile.TemporaryDirectory(prefix="haxeon-stdout-") as directory:
        project = Path(directory)
        (project / "src").mkdir()
        def compile_body(body, extra=""):
            (project / "src/Main.hx").write_text(
                extra + '\nclass Main { static function main():Void { ' + body + ' } }\n')
            bytecode = project / "main.hl"
            subprocess.run([str(ROOT / ".tools/haxe/haxe"), "-cp", str(project / "src"),
                "-main", "Main", "-hl", str(bytecode)], check=True, capture_output=True, text=True)
            return [str(ROOT / ".tools/hashlink/hl"), str(bytecode)]

        # First test: a real null dereference must retain the pending tail.
        compile_body('Sys.println("before-crash"); var box:Box = null; Sys.println(box.value);',
            'class Box { public var value:Int; public function new() { value = 1; } }')
        config = project / "haxeon.json"
        config.write_text(json.dumps({"version": 1, "package": {"name": "stdout-check"},
            "entry": "Main", "sourceRoots": ["src"], "target": "host", "outputDir": "build"}))
        subprocess.run([str(ROOT / "scripts/haxeon"), "build", "--compiler-only",
            "--project", str(config), "--output", str(project / "main.hl")], check=True, capture_output=True)
        command = [str(ROOT / ".tools/hashlink/hl"), str(project / "main.hl")]
        result = subprocess.run(command, env=environment, capture_output=True, timeout=5)
        assert result.returncode == -signal.SIGSEGV, result
        assert result.stdout == b"before-crash\n", result

        # Exercise the native fatal-error path, which can trap before exit().
        native = project / "fatal.c"
        native.write_text('#include "hl.h"\n#include <stdio.h>\n'
            'int main(void) { hl_global_init(); hl_register_thread(NULL); '
            'fputs("before-fatal", stdout); hl_fatal("stdout-test"); return 0; }\n')
        subprocess.run([os.environ.get("CC", "cc"), str(native),
            "-I", str(ROOT / "vendor/hashlink/src"), "-L", str(ROOT / ".tools/hashlink"),
            "-Wl,-rpath," + str(ROOT / ".tools/hashlink"), "-lhl", "-o", str(project / "fatal")],
            check=True, capture_output=True)
        result = subprocess.run([str(project / "fatal")], env=environment,
            capture_output=True, timeout=5)
        assert result.returncode != 0 and result.stdout.startswith(b"before-fatal"), result
        assert b"FATAL ERROR" in result.stdout, result

        for body, code in [
            ('Sys.print("tail");', 0),
            ('Sys.print("tail"); Sys.exit(7);', 7),
            ('Sys.print("tail"); throw "boom";', 1),
        ]:
            result = subprocess.run(compile_body(body), env=environment,
                capture_output=True, timeout=5)
            assert result.returncode == code and result.stdout == b"tail", result

        result = subprocess.run(compile_body('Sys.print("parent\\n"); Sys.command("printf child");'),
            env=environment, capture_output=True, timeout=5)
        assert result.returncode == 0 and result.stdout == b"parent\nchild", result

        # Each program stays alive at stdin so readiness proves a timely flush.
        for body, override in [
            ('Sys.print("prompt"); Sys.stdin().readByte();', False),
            ('Sys.print("prompt"); Sys.getChar(false);', False),
            ('Sys.print("prompt"); Sys.stdin().readBytes(haxe.io.Bytes.alloc(1), 0, 1);', False),
            ('Sys.print("prompt"); Sys.stdout().flush(); while (true) {}', False),
            ('Sys.print("prompt"); Sys.sleep(30);', False),
            ('Sys.print("prompt"); while (true) {}', True),
            ('Sys.print("prompt"); var p = new sys.io.Process("/bin/true", []); while (true) {}', False),
        ]:
            env = environment.copy()
            if override:
                env["HL_STDOUT_FLUSH"] = "1"
            process = subprocess.Popen(compile_body(body), env=env,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                assert select.select([process.stdout], [], [], 3)[0], body
                assert os.read(process.stdout.fileno(), 6) == b"prompt", body
            finally:
                process.kill()
                process.communicate(timeout=5)

        # Terminal output remains immediately visible, even without a newline.
        master, slave = pty.openpty()
        process = subprocess.Popen(compile_body('Sys.print("terminal"); while (true) {}'),
            env=environment, stdout=slave, stderr=subprocess.PIPE)
        os.close(slave)
        try:
            assert select.select([master], [], [], 3)[0]
            assert os.read(master, 8) == b"terminal"
        finally:
            process.kill()
            process.communicate(timeout=5)
            os.close(master)

        with (project / "stdout.txt").open("wb") as output:
            result = subprocess.run(compile_body('Sys.print("file-tail");'), env=environment,
                stdout=output, stderr=subprocess.PIPE, timeout=5)
        assert result.returncode == 0
        assert (project / "stdout.txt").read_bytes() == b"file-tail"

        # No implicit flush for redirected output during ordinary computation.
        process = subprocess.Popen(compile_body('Sys.println("buffered"); while (true) {}'),
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert not select.select([process.stdout], [], [], 0.3)[0]
        finally:
            process.kill()
            process.communicate(timeout=5)
    print("HashLink stdout buffering passed")


if __name__ == "__main__":
    main()
