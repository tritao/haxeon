/**
 * A local assigned inside `try` reaches `catch` with its latest value, whatever path reached the `try`: a value merged from
 * two branches, a loop-carried value, or nested trys. The JIT stores such writes to the slot `catch` reads, found from the
 * block that entered each try. Compiled by Haxe, not by Haxeon, so it runs the standard bytecode shapes.
 */
class JitTryLocalWritesMain {
	static function thrower(fail:Bool):Int {
		if (fail)
			throw "fail";
		return 0;
	}

	static function merged(cond:Bool):Int {
		var x = 0;
		if (cond)
			x = 1;
		else
			x = 2;
		try {
			x = 10;
			thrower(true);
			x = 20;
		} catch (e:Dynamic) {
			return x;
		}
		return -1;
	}

	static function nested(cond:Bool):Int {
		var x = cond ? 1 : 2;
		try {
			x = 3;
			try {
				x = 4;
				thrower(true);
			} catch (e:Dynamic) {
				x += 10;
				thrower(true);
			}
		} catch (e:Dynamic) {
			return x;
		}
		return -1;
	}

	static function looped(n:Int):Int {
		var total = 0;
		for (i in 0...n) {
			try {
				total += i;
				thrower(i == n - 1);
			} catch (e:Dynamic) {
				return total;
			}
		}
		return -1;
	}

	static function derived(cond:Bool):Int {
		var y = cond ? 5 : 6;
		var z = y;
		try {
			z = y * 2;
			thrower(true);
		} catch (e:Dynamic) {
			return z;
		}
		return -1;
	}

	static function main():Void {
		var got = [
			merged(true),
			merged(false),
			nested(true),
			nested(false),
			looped(4),
			derived(true),
			derived(false)
		];
		var want = [10, 10, 14, 14, 6, 10, 12];
		if (got.join(",") != want.join(",")) {
			Sys.println("FAIL: catch saw " + got.join(",") + " instead of " + want.join(","));
			Sys.exit(1);
		}
		Sys.println("PASS: locals written in try reach catch on every path into the try");
	}
}
