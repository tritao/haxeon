package compiler.types;

/** The optional-argument flags of a `TFunction`, which may be shorter than its arguments: a missing flag is false. */
class FunctionTypes {
	/** The flags of a function declared with `arguments`. */
	public static function ofArguments(arguments:Array<compiler.syntax.Ast.AstArgument>):Array<Bool>
		return canonical([for (argument in arguments) compiler.syntax.AstPredicates.isOptionalArgument(argument)]);

	/** Whether argument `index` may be omitted. */
	public static function isOptional(optional:Array<Bool>, index:Int):Bool
		return index < optional.length && optional[index];

	/** The flags in their shortest form, without trailing false flags, so equal flags have equal arrays. */
	public static function canonical(optional:Array<Bool>):Array<Bool> {
		var length = optional.length;
		while (length > 0 && !optional[length - 1])
			length--;
		return length == optional.length ? optional : optional.slice(0, length);
	}

	public static function sameOptional(left:Array<Bool>, right:Array<Bool>):Bool {
		var length = left.length > right.length ? left.length : right.length;
		for (index in 0...length)
			if (isOptional(left, index) != isOptional(right, index))
				return false;
		return true;
	}

	/** Whether a value of a function type with flags `actual` can stand for one with `expected`: Haxe's `Cant_force_optional`. */
	public static function acceptsOptional(actual:Array<Bool>, expected:Array<Bool>):Bool {
		for (index in 0...expected.length)
			if (expected[index] && !isOptional(actual, index))
				return false;
		return true;
	}

	/** How many leading arguments a call must pass: those up to the last required one. */
	public static function requiredCount(optional:Array<Bool>, argumentCount:Int):Int {
		var required = argumentCount;
		while (required > 0 && isOptional(optional, required - 1))
			required--;
		return required;
	}
}
