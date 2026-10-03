/**
 * Unboxing a dynamic value into a register that a nested try block then assigns. The JIT remembers the last value stored
 * to each register for the code inside try blocks, so the unbox must leave that record naming a value that exists on every
 * path. Compiled by Haxe, not by Haxeon, so it runs the standard bytecode shapes.
 */
class JitDynamicUnboxMain {
	static function fail(code:Int, message:String):Void {
		Sys.println("FAIL: " + message);
		Sys.exit(code);
	}

	static function catchInt():Int {
		try {
			throw 1;
		} catch (value:Int) {
			try {
				value = 42;
				throw "stop";
			} catch (error:Dynamic) {}
			return value;
		}
	}

	static function catchFloat():Float {
		try {
			throw 1.5;
		} catch (value:Float) {
			try {
				value = 42.5;
				throw "stop";
			} catch (error:Dynamic) {}
			return value;
		}
	}

	static function unboxThenAssign(boxed:Dynamic):Int {
		var number:Int = boxed;
		try {
			number = number + 1;
			throw "stop";
		} catch (error:Dynamic) {}
		return number;
	}

	static function main():Void {
		if (catchInt() != 42)
			fail(1, "catch variable assigned inside a nested try, Int");
		if (catchFloat() != 42.5)
			fail(2, "catch variable assigned inside a nested try, Float");
		if (unboxThenAssign(9) != 10)
			fail(3, "unboxed Int updated inside a try");
		if (unboxThenAssign(null) != 1)
			fail(4, "null unboxed to zero, then updated inside a try");
		Sys.println("PASS: unboxed dynamic values survive assignment in nested try blocks");
	}
}
