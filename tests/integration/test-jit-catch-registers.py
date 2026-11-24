#!/usr/bin/env python3
"""A catch sees every register as it was when the exception was thrown, built by stock Haxe and run on the fork's JIT.

The JIT keeps each register a try region writes in a catch slot of its own, which the catch path reloads (jit_emit.c,
OTrap). Two shapes stock Haxe's code generator writes are checked:

- a `try` used as an expression puts its result in the trap's own exception register, so the region writes that register:
  the catch must still receive the exception, not the result the region was computing;
- a local written inside the try, before and after the throwing call, read in the catch, also when the try is entered
  from a branch merge or a loop, and through nested trys that rethrow;
- a local a callee writes through a reference (`hl.Ref`, ORef) inside the try: a referenced register lives in one stack
  home, so the catch reads what the callee wrote.

Haxeon's own register reuse across a try is covered by tests/programs/try-register-sharing.hx and generic-struct-class.hx in
release builds.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HASHLINK_DIR = Path(subprocess.check_output([str(ROOT / "scripts/hashlink-path.sh")], text=True).strip())
VM = os.environ.get("HL_JIT_TEST_VM") or str(HASHLINK_DIR / "hl")
HAXE = ROOT / ".tools" / "haxe" / ("haxe.exe" if os.name == "nt" else "haxe")

PROGRAM = r'''
class Main {
	@:noInline static function fail(at:Int, now:Int):Int {
		if (at == now)
			throw "thrown-" + now;
		return now * 10;
	}

	@:noInline static function flag(on:Bool):Bool
		return on;

	// The try's value goes to the trap's own register; the catch must receive the exception.
	@:noInline static function tryExpression(at:Int):String {
		var result:Dynamic = try {
			var computed:Dynamic = flag(true);
			fail(at, 1);
			computed;
		} catch (e:Dynamic) {
			"caught:" + e;
		}
		return Std.string(result);
	}

	@:noInline static function rethrowFromExpression(at:Int):String {
		try {
			var inner:Dynamic = try {
				var temp:Dynamic = flag(true);
				fail(at, 2);
				temp;
			} catch (e:Dynamic) {
				throw e;
			}
			return "inner:" + inner;
		} catch (e:Dynamic) {
			return "outer:" + e;
		}
	}

	@:noInline static function writtenInTry(at:Int, start:Int):Int {
		var progress = start;
		try {
			// Each write reads the last, so the code generator stores every one (with independent writes, stock Haxe
			// computes into a temporary and assigns the local once, at the end of the try).
			progress = fail(at, 1) + progress + 1;
			progress = fail(at, 2) + progress + 2;
			progress = fail(at, 3) + progress + 3;
		} catch (e:String) {
			return progress;
		}
		return -progress;
	}

	@:noInline static function enteredFromMerge(at:Int, left:Bool):Int {
		var value = left ? 7 : 8;
		try {
			value = fail(at, 1) + value;
			value = fail(at, 2) + value;
		} catch (e:String) {
			return value;
		}
		return -value;
	}

	@:noInline static function inLoop(at:Int):Int {
		var total = 0;
		for (i in 0...4) {
			try {
				total += fail(at, i);
			} catch (e:String) {
				total += 1000;
			}
		}
		return total;
	}

	@:noInline static function bump(r:hl.Ref<Int>, by:Int):Void
		r.set(r.get() + by);

	// A callee writes the local through a reference, then the region throws: the catch reads what the callee wrote.
	@:noInline static function referenceInTry(at:Int):Int {
		var counted = 1;
		try {
			bump(counted, 10);
			fail(at, 1);
			bump(counted, 100);
			fail(at, 2);
		} catch (e:String) {
			return counted;
		}
		return -counted;
	}

	// The same with the local also written directly between the callee's writes.
	@:noInline static function referenceAndWrites(at:Int):Int {
		var counted = 1;
		try {
			bump(counted, 10);
			counted = counted * 2;
			fail(at, 1);
			bump(counted, 100);
			fail(at, 2);
		} catch (e:String) {
			return counted;
		}
		return -counted;
	}

	static function check(name:String, got:Dynamic, want:Dynamic):Void
		if (got != want) {
			Sys.println('FAIL: $name: got $got, want $want');
			Sys.exit(1);
		}

	static function main() {
		check("try expression, no throw", tryExpression(0), "true");
		check("try expression, throw", tryExpression(1), "caught:thrown-1");
		check("rethrow from a try expression", rethrowFromExpression(2), "outer:thrown-2");
		check("rethrow, no throw", rethrowFromExpression(0), "inner:true");
		check("written before the first throw", writtenInTry(1, 5), 5);
		check("written once", writtenInTry(2, 5), 16);
		check("written twice", writtenInTry(3, 5), 38);
		check("not thrown", writtenInTry(0, 5), -71);
		check("entered from a merge, left", enteredFromMerge(1, true), 7);
		check("entered from a merge, right, second", enteredFromMerge(2, false), 18);
		check("in a loop", inLoop(2), 0 + 10 + 1000 + 30);
		check("written through a reference, first throw", referenceInTry(1), 11);
		check("written through a reference, second throw", referenceInTry(2), 111);
		check("written through a reference, no throw", referenceInTry(0), -111);
		check("reference and writes, first throw", referenceAndWrites(1), 22);
		check("reference and writes, second throw", referenceAndWrites(2), 122);
		Sys.println("ok");
	}
}
'''


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="haxeon-jit-catch-") as work:
        Path(work, "Main.hx").write_text(PROGRAM)
        module = str(Path(work, "main.hl"))
        subprocess.run([str(HAXE), "-cp", work, "-main", "Main", "-hl", module], check=True)
        env = dict(os.environ)
        env["LD_LIBRARY_PATH"] = os.pathsep.join(p for p in [str(ROOT / "out"), str(HASHLINK_DIR),
                                                             env.get("LD_LIBRARY_PATH", "")] if p)
        run = subprocess.run([VM, module], capture_output=True, text=True, env=env)
        if run.returncode != 0 or run.stdout.strip() != "ok":
            sys.stderr.write(run.stdout + run.stderr)
            print(f"FAIL: catch registers (exit {run.returncode})")
            return 1
    print("PASS: a catch sees the exception and every register as the throw left it, on stock Haxe's code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
