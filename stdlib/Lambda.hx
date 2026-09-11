/** Compatibility helpers for iterable-style collection operations. */
class Lambda {
	public static function find<T>(values:Array<T>, predicate:T->Bool):Null<T> {
		for (value in values)
			if (predicate(value))
				return value;
		return null;
	}
}
