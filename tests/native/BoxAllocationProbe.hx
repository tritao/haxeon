@:hlNative("jitbox") private extern class BoxHooks {
	static function mode(value:Int):Void;
	static function eligibility():Bool;
	static function count():Int;
	static function major():Void;
	static function padding(value:Dynamic):Bool;
	static function value(value:Dynamic):Int;
}

class BoxAllocationProbe {
	static var keep:Array<Dynamic> = [];

	@:noInline static function boxed(value:Int):Dynamic {
		return value;
	}

	static function allocate(n:Int):Bool {
		for (i in 0...n) {
			var v = boxed(i - 500);
			var actual = BoxHooks.value(v);
			if (actual != i - 500 || !BoxHooks.padding(v))
				return false;
			keep[i & 127] = v;
		}
		return true;
	}

	static function fail(code:Int):Void {
		BoxHooks.mode(0);
		Sys.exit(code);
	}

	static function main():Void {
		if (!BoxHooks.eligibility())
			fail(8);
		if (!allocate(1000))
			fail(1);
		BoxHooks.major();
		for (mode in 1...4) {
			if (!allocate(17))
				fail(2);
			BoxHooks.mode(mode);
			if (!allocate(1000))
				fail(3);
			var count = BoxHooks.count();
			if (mode != 2 && count < 1000)
				fail(4);
			BoxHooks.mode(0);
		}
		if (!allocate(100000))
			fail(5);
		var a = 1.0, b = 2.0, c = 3.0, d = 4.0, e = 5.0, f = 6.0;
		var live = boxed(42);
		for (i in 0...100000) {
			var sentinel = a + 0.25;
			var v:Dynamic = i - 50000;
			a = sentinel + 0.75;
			b += 2;
			c += 3;
			d += 4;
			e += 5;
			f += 6;
			var actual = BoxHooks.value(v);
			if (actual != i - 50000 || !BoxHooks.padding(v))
				fail(6);
			keep[i & 127] = v;
		}
		BoxHooks.major();
		if (a + b + c + d + e + f != 2100021.0 || BoxHooks.value(live) != 42)
			fail(7);
		Sys.println("PASS: integer box defaults, dirty padding, live values and runtime hooks");
	}
}
