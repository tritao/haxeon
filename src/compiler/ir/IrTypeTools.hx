package compiler.ir;

import compiler.ir.Ir.IrType;

/** Rules about IR types that more than one stage needs. */
class IrTypeTools {
	/** Whether values of this type are boxed dynamic values: `Dyn`, or a nullable primitive (which is one). */
	public static function isDynamic(type:IrType):Bool
		return switch type {
			case Dyn, Nullable(_): true;
			default: false;
		};

	/** The primitive a `Nullable` holds, or null for any other type. */
	public static function nullableElement(type:IrType):Null<IrType>
		return switch type {
			case Nullable(element): element;
			default: null;
		};

	/** The type with every `Nullable` replaced by `Dyn`, which is what backends without a nullable representation use. */
	public static function erase(type:IrType):IrType
		return switch type {
			case Nullable(_): Dyn;
			case Array(element): changed(type, Array(erase(element)), element);
			case Iterator(element): changed(type, Iterator(erase(element)), element);
			case Function(arguments, result):
				var erasedArguments = [for (argument in arguments) erase(argument)],
					erasedResult = erase(result);
				var same = Std.string(erasedResult) == Std.string(result);
				for (index in 0...arguments.length)
					if (Std.string(erasedArguments[index]) != Std.string(arguments[index]))
						same = false;
				same ? type : Function(erasedArguments, erasedResult);
			default: type;
		};

	/** Whether the type mentions `Nullable` anywhere. */
	public static function containsNullable(type:IrType):Bool
		return switch type {
			case Nullable(_): true;
			case Array(element), Iterator(element): containsNullable(element);
			case Function(arguments, result):
				var found = containsNullable(result);
				for (argument in arguments)
					if (containsNullable(argument))
						found = true;
				found;
			default: false;
		};

	/**
	 * Whether a value of type `actual` may stand where `expected` is required without an operation. Equal types may, and a
	 * nullable primitive may stand where a `Dyn` is required. The reverse needs a `SafeCast`, which also converts a box of
	 * another kind, so that a value typed as `Null<Int>` really is an Int box (or null).
	 */
	public static function compatible(expected:IrType, actual:IrType):Bool
		return Std.string(expected) == Std.string(actual) || (expected == Dyn && nullableElement(actual) != null);

	static function changed(original:IrType, replacement:IrType, element:IrType):IrType
		return Std.string(erase(element)) == Std.string(element) ? original : replacement;
}
