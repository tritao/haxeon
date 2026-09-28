package haxeon;

/**
	Array methods written in Haxe instead of built into the compiler. A call
	`values.name(arguments)` that the compiler does not implement natively is
	typed as `ArrayMethods.name(values, arguments)`, so adding an array method
	means adding a generic function here.
**/
class ArrayMethods {
	public static function filter<T>(values:Array<T>, predicate:T->Bool):Array<T> {
		var result:Array<T> = [];
		for (value in values)
			if (predicate(value))
				result.push(value);
		return result;
	}

	public static function map<T, S>(values:Array<T>, transform:T->S):Array<S> {
		var result:Array<S> = [];
		for (value in values)
			result.push(transform(value));
		return result;
	}

	/** Joins elements that are not Strings (which the runtime joins directly) through `Std.string`. */
	public static function join<T>(values:Array<T>, separator:String):String {
		var parts:Array<String> = [];
		for (value in values)
			parts.push(Std.string(value));
		return parts.join(separator);
	}
}
