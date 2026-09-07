package utest;

/**
 * Small, source-compatible core of utest assertions for Haxeon.
 *
 * Haxeon does not yet provide PosInfos or the reflection surface used by the
 * upstream implementation, so failures are reported as strings and collected
 * by Runner.
 */
class Assert {
	public static function isTrue(condition:Bool, message:String = ""):Bool {
		if (!condition)
			fail(message == "" ? "expected true" : message);
		return true;
	}

	public static function isFalse(condition:Bool, message:String = ""):Bool {
		if (condition)
			fail(message == "" ? "expected false" : message);
		return true;
	}

	public static function equals<T>(expected:T, actual:T, message:String = ""):Bool {
		if (expected != actual)
			Assert.fail(message == "" ? "expected " + Std.string(expected) + " but it is " + Std.string(actual) : message);
		return true;
	}

	public static function notEquals<T>(expected:T, actual:T, message:String = ""):Bool {
		if (expected == actual)
			Assert.fail(message == "" ? "expected values to be different: " + Std.string(actual) : message);
		return true;
	}

	public static function isNull<T>(value:Null<T>, message:String = ""):Bool {
		if (value != null)
			Assert.fail(message == "" ? "expected null but it is " + Std.string(value) : message);
		return true;
	}

	public static function notNull<T>(value:Null<T>, message:String = ""):Bool {
		if (value == null)
			Assert.fail(message == "" ? "expected not null" : message);
		return true;
	}

	public static function fail(message:String = "assertion failed"):Bool {
		throw message;
	}
}
