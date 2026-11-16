#!/usr/bin/env python3
"""A JIT frame of several pages is probed a page at a time, so overflowing a worker's stack faults in its guard page.

Without probes a prologue moves SP past the guard without touching it, and the frame's first write (the call at its bottom)
lands below the guard: in another mapping, silently, or faulting away from the guard. Whether it still hits the guard depends
on where the stack stands when the overflow starts, so the worker first recurses through a padding function a varying number
of times, and every start must fault in the guard the thread's stack has below its usable range.
"""
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HASHLINK_DIR = Path(os.environ.get("HL_GC_TEST_LIBRARY_DIR") or
                    subprocess.check_output([str(ROOT / "scripts/hashlink-path.sh")], text=True).strip())
VM = os.environ.get("HL_JIT_TEST_VM") or str(HASHLINK_DIR / "hl")
LIVE_VALUES = 2000  # live across the recursive call, so each frame holds them: about four pages
PAD_VALUES = 250  # a padding frame of about half a page, to shift where the overflow starts
STARTS = 8  # padding depths 0..7 move the start across a whole big frame's worth of alignments


def frame(count: int) -> tuple[str, str]:
    declarations = "\n".join(f"\t\tvar v{i} = id(depth + {i}.0);" for i in range(count))
    return declarations, " + ".join(f"v{i}" for i in range(count))


def program() -> str:
    declarations, total = frame(LIVE_VALUES)
    pad_declarations, pad_total = frame(PAD_VALUES)
    return f'''@:hlNative("stack_probe") extern class Hooks {{
	static function measure():Bool;
	static function low_high():Int;
	static function low_low():Int;
	static function guard():Int;
}}

class Main {{
	@:noInline static function id(v:Float):Float
		return v;

	static function big(depth:Int):Float {{
{declarations}
		var deeper = big(depth + 1);
		return deeper + {total};
	}}

	static function pad(depth:Int, remaining:Int):Float {{
		if (remaining == 0)
			return big(0);
{pad_declarations}
		var deeper = pad(depth + 1, remaining - 1);
		return deeper + {pad_total};
	}}

	static function main() {{
		var padding = Std.parseInt(Sys.args()[0]);
		sys.thread.Thread.create(() -> {{
			if (!Hooks.measure())
				Sys.exit(3);
			Sys.println("guard " + Hooks.low_high() + " " + Hooks.low_low() + " " + Hooks.guard());
			Sys.stdout().flush();
			pad(0, padding);
		}});
		while (true)
			Sys.sleep(1.0);
	}}
}}
'''
# A native library's hl_* symbols resolve against the VM that loads it; macOS's linker needs to be told so, as CMakeLists.txt
# does for the runtime library.
HOST_SYMBOLS = ["-Wl,-undefined,dynamic_lookup"] if sys.platform == "darwin" else []
# A thread's stack guard is a protection fault: macOS reports it as SIGBUS, Linux as SIGSEGV.
GUARD_SIGNAL = signal.SIGBUS if sys.platform == "darwin" else signal.SIGSEGV


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix="haxeon-stack-probe-") as directory:
        work = Path(directory)
        subprocess.run([os.environ.get("CC", "cc"), "-shared", "-fPIC", "-I", str(ROOT / "vendor/hashlink/src"),
                        str(ROOT / "tests/native/stack_probe_hooks.c"), "-o", str(work / "stack_probe.hdll")] + HOST_SYMBOLS,
                       check=True)
        (work / "Main.hx").write_text(program())
        subprocess.run([str(ROOT / ".tools/haxe/haxe"), "-cp", str(work), "-main", "Main", "-hl", str(work / "probe.hl")],
                       check=True, capture_output=True, text=True)
        environment = os.environ.copy()
        for variable in ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]:
            environment[variable] = os.pathsep.join([str(work), str(ROOT / "out"), str(HASHLINK_DIR),
                                                     environment.get(variable, "")])
        for padding in range(STARTS):
            result = subprocess.run([VM, str(work / "probe.hl"), str(padding)], env=environment, capture_output=True,
                                    text=True, timeout=120)
            assert result.returncode == -GUARD_SIGNAL, result
            guard = re.search(r"^guard (-?\d+) (-?\d+) (\d+)$", result.stdout, re.M)
            fault = re.search(rf"HashLink fatal error: {GUARD_SIGNAL.name} \(signal {int(GUARD_SIGNAL)}\) at (0x[0-9a-f]+)",
                              result.stderr)
            assert guard and fault, result
            low = ((int(guard.group(1)) & 0xFFFFFFFF) << 32) | (int(guard.group(2)) & 0xFFFFFFFF)
            size, address = int(guard.group(3)), int(fault.group(1), 16)
            assert low - size <= address < low, \
                f"padding {padding}: fault at {address:#x}, {low - address:#x} below the stack; the guard is {size:#x}"
    print("PASS: overflowing a worker through multi-page JIT frames faults in its stack guard")


if __name__ == "__main__":
    main()
