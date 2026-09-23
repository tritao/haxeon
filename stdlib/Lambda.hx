/** Compatibility helpers for iterable-style collection operations. */
class Lambda {
	public static function has<T>(values:Array<T>, expected:T):Bool {
		for (value in values)
			if (value == expected)
				return true;
		return false;
	}

	public static function find<T>(values:Array<T>, predicate:T->Bool):Null<T> {
		for (value in values)
			if (predicate(value))
				return value;
		return null;
	}

	public static function exists<T>(values:Array<T>, predicate:T->Bool):Bool {
		for (value in values)
			if (predicate(value))
				return true;
		return false;
	}
}
