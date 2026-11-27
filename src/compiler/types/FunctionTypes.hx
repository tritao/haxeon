package compiler.types;

import compiler.types.Type.CompilerType;

/**
 * The argument lists of a `TFunction`: its optional-argument flags, which may be shorter than its arguments (a missing flag
 * is false), and its `Void` arguments, which take none.
 */
class FunctionTypes {
	/**
	 * Whether a function type has an argument of type `Void`, which takes none (`VoidArguments`): `T->U` at `T` = `Void` is the
	 * function with no arguments, so function types compare and unify by their other arguments (`withoutUnits`).
	 */
	public static function hasUnit(arguments:Array<CompilerType>):Bool {
		for (argument in arguments)
			if (Monomorphs.follow(argument).match(TVoid))
				return true;
		return false;
	}

	/** `arguments` without their `Void` ones, and `optional` in step; both as given when there are none. */
	public static function withoutUnits(arguments:Array<CompilerType>,
			optional:Array<Bool>):{
				arguments:Array<CompilerType>,
				optional:Array<Bool>
			} {
		if (!hasUnit(arguments))
			return {arguments: arguments, optional: optional};
		var kept:Array<CompilerType> = [], flags:Array<Bool> = [];
		for (index in 0...arguments.length)
			if (!Monomorphs.follow(arguments[index]).match(TVoid)) {
				kept.push(arguments[index]);
				flags.push(isOptional(optional, index));
			}
		return {arguments: kept, optional: flags};
	}

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
