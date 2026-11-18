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

	/** A new Array of the values, in order (a copy when `values` is an Array). */
	public static function array<T>(values:Iterable<T>):Array<T> {
		var result = new Array<T>();
		for (value in values)
			result.push(value);
		return result;
	}

	/** A new Array of `f` applied to each value, in order. */
	public static function map<T, S>(values:Iterable<T>, f:(item:T) -> S):Array<S> {
		var result = new Array<S>();
		for (value in values)
			result.push(f(value));
		return result;
	}

	/** `map`, with each value's index passed first. */
	public static function mapi<T, S>(values:Iterable<T>, f:(index:Int, item:T) -> S):Array<S> {
		var result = new Array<S>(), index = 0;
		for (value in values)
			result.push(f(index++, value));
		return result;
	}

	/** Whether `predicate` holds for every value (true when there is none). */
	public static function foreach<T>(values:Iterable<T>, predicate:(item:T) -> Bool):Bool {
		for (value in values)
			if (!predicate(value))
				return false;
		return true;
	}

	/** Calls `f` on each value, in order. */
	public static function iter<T>(values:Iterable<T>, f:(item:T) -> Void):Void {
		for (value in values)
			f(value);
	}

	/** A new Array of the values `predicate` accepts, in order. */
	public static function filter<T>(values:Iterable<T>, predicate:(item:T) -> Bool):Array<T> {
		var result = new Array<T>();
		for (value in values)
			if (predicate(value))
				result.push(value);
		return result;
	}

	/** `f` applied to each value and the result so far, starting from `first`. */
	public static function fold<T, S>(values:Iterable<T>, f:(item:T, result:S) -> S, first:S):S {
		for (value in values)
			first = f(value, first);
		return first;
	}

	/** `fold`, with each value's index passed last. */
	public static function foldi<T, S>(values:Iterable<T>, f:(item:T, result:S, index:Int) -> S, first:S):S {
		var index = 0;
		for (value in values)
			first = f(value, first, index++);
		return first;
	}

	/** Whether there is no value. */
	public static function empty<T>(values:Iterable<T>):Bool
		return !values.iterator().hasNext();

	/** The position of the first value equal to `expected` (`==`), or -1. */
	public static function indexOf<T>(values:Iterable<T>, expected:T):Int {
		var index = 0;
		for (value in values) {
			if (value == expected)
				return index;
			index++;
		}
		return -1;
	}

	/** The position of the first value `predicate` accepts, or -1. */
	public static function findIndex<T>(values:Iterable<T>, predicate:(item:T) -> Bool):Int {
		var index = 0;
		for (value in values) {
			if (predicate(value))
				return index;
			index++;
		}
		return -1;
	}

	/** A new Array of the values of `first`, then those of `second`. */
	public static function concat<T>(first:Iterable<T>, second:Iterable<T>):Array<T> {
		var result = new Array<T>();
		for (value in first)
			result.push(value);
		for (value in second)
			result.push(value);
		return result;
	}
}
