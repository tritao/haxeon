/** Compatibility helpers for iterable-style collection operations. */
class Lambda {
	public static function has<T>(values:Iterable<T>, expected:T):Bool {
		for (value in values)
			if (value == expected)
				return true;
		return false;
	}

	public static function find<T>(values:Iterable<T>, predicate:T->Bool):Null<T> {
		for (value in values)
			if (predicate(value))
				return value;
		return null;
	}

	public static function exists<T>(values:Iterable<T>, predicate:T->Bool):Bool {
		for (value in values)
			if (predicate(value))
				return true;
		return false;
	}

	/** The number of values, or of those `predicate` accepts. */
	public static function count<T>(values:Iterable<T>, ?predicate:T->Bool):Int {
		if (predicate == null && Std.isOfType(values, Array))
			return (cast(values, Array<T>)).length;
		var total = 0;
		for (value in values)
			if (predicate == null || predicate(value))
				total++;
		return total;
	}
}
