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

	public static function floatEquals(expected:Float, actual:Float, approximation:Float = 0.00001, message:String = ""):Bool {
		var difference = actual - expected;
		if (difference < 0.0)
			difference = -difference;
		var equal = Math.isNaN(expected) ? Math.isNaN(actual) : !Math.isNaN(actual) && difference <= approximation;
		if (!equal)
			Assert.fail(message == "" ? "expected " + Std.string(expected) + " but it is " + Std.string(actual) : message);
		return true;
	}

	public static function contains<T>(match:T, values:Array<T>, message:String = ""):Bool {
		if (values.indexOf(match) < 0)
			Assert.fail(message == "" ? "values do not contain " + Std.string(match) : message);
		return true;
	}

	public static function notContains<T>(match:T, values:Array<T>, message:String = ""):Bool {
		if (values.indexOf(match) >= 0)
			Assert.fail(message == "" ? "values contain " + Std.string(match) : message);
		return true;
	}

	/** Asserts that a callback raises any exception. Typed exception checks require reflection and are not yet supported. */
	public static function raises(method:() -> Void, message:String = ""):Bool {
		try {
			method();
		} catch (error:Dynamic) {
			return true;
		}
		Assert.fail(message == "" ? "expected exception but none was raised" : message);
	}

	public static function fail(message:String = "assertion failed"):Bool {
		throw message;
	}
}
