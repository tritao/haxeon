package utest;

import haxe.PosInfos;

/**
 * The core of utest's assertions, source-compatible with it. A failed assertion throws, with its message and position, so
 * the test stops at it and `Runner` counts the test failed; each returns true when it holds.
 */
class Assert {
	/** Fails the test, with `message` when given, unless `condition` is true. */
	public static function isTrue(condition:Bool, message:String = "", ?pos:PosInfos):Bool {
		if (!condition)
			fail(message == "" ? "expected true" : message, pos);
		return true;
	}

	/** Fails the test, with `message` when given, unless `condition` is false. */
	public static function isFalse(condition:Bool, message:String = "", ?pos:PosInfos):Bool {
		if (condition)
			fail(message == "" ? "expected false" : message, pos);
		return true;
	}

	/** Fails the test, with `message` or both values, unless `actual == expected`. */
	public static function equals<T>(expected:T, actual:T, message:String = "", ?pos:PosInfos):Bool {
		if (expected != actual)
			Assert.fail(message == ""
				? "expected " + Std.string(expected) + " but it is " + Std.string(actual) : message, pos);
		return true;
	}

	/** Fails the test, with `message` or the value, when `actual == expected`. */
	public static function notEquals<T>(expected:T, actual:T, message:String = "", ?pos:PosInfos):Bool {
		if (expected == actual)
			Assert.fail(message == "" ? "expected values to be different: " + Std.string(actual) : message, pos);
		return true;
	}

	/** Fails the test, with `message` or the value, unless `value` is null. */
	public static function isNull<T>(value:Null<T>, message:String = "", ?pos:PosInfos):Bool {
		if (value != null)
			Assert.fail(message == "" ? "expected null but it is " + Std.string(value) : message, pos);
		return true;
	}

	/** Fails the test, with `message` when given, when `value` is null. */
	public static function notNull<T>(value:Null<T>, message:String = "", ?pos:PosInfos):Bool {
		if (value == null)
			Assert.fail(message == "" ? "expected not null" : message, pos);
		return true;
	}

	/**
	 * Fails the test, with `message` or both values, unless `actual` is within `approximation` of `expected`. NaN
	 * equals NaN here.
	 */
	public static function floatEquals(expected:Float, actual:Float, approximation:Float = 0.00001, message:String = "",
			?pos:PosInfos):Bool {
		var difference = actual - expected;
		if (difference < 0.0)
			difference = -difference;
		var equal = Math.isNaN(expected) ? Math.isNaN(actual) : !Math.isNaN(actual) && difference <= approximation;
		if (!equal)
			Assert.fail(message == ""
				? "expected " + Std.string(expected) + " but it is " + Std.string(actual) : message, pos);
		return true;
	}

	/** Fails the test, with `message` or the value, unless one of `values` is `match`. */
	public static function contains<T>(match:T, values:Array<T>, message:String = "", ?pos:PosInfos):Bool {
		if (values.indexOf(match) < 0)
			Assert.fail(message == "" ? "values do not contain " + Std.string(match) : message, pos);
		return true;
	}

	/** Fails the test, with `message` or the value, when one of `values` is `match`. */
	public static function notContains<T>(match:T, values:Array<T>, message:String = "", ?pos:PosInfos):Bool {
		if (values.indexOf(match) >= 0)
			Assert.fail(message == "" ? "values contain " + Std.string(match) : message, pos);
		return true;
	}

	/** Asserts that a callback raises any exception. Typed exception checks require reflection and are not yet supported. */
	public static function raises(method:() -> Void, message:String = "", ?pos:PosInfos):Bool {
		try {
			method();
		} catch (error:Dynamic) {
			return true;
		}
		return Assert.fail(message == "" ? "expected exception but none was raised" : message, pos);
	}

	/**
	 * Fails the test with `message`, at `pos`: it throws, so the test stops there and the runner counts it as failed.
	 */
	public static function fail(message:String = "assertion failed", ?pos:PosInfos):Bool {
		if (pos != null)
			throw pos.fileName + ":" + pos.lineNumber + ": " + message;
		throw message;
	}
}
