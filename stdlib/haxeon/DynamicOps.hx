package haxeon;

/**
	Operators whose operand is a Dynamic value: what the values are, Int, Float or String, is only known when the
	program runs, so the typer calls these where an operand is Dynamic. The result types are Haxe's: `+` is Dynamic
	(two Ints give an Int, a String joins, anything else a Float), `-`, `*`, `/`, `%` and negation are Float, the bitwise
	and shift operators are Int, and the comparisons are Bool.
**/
class DynamicOps {
	public static function add(left:Dynamic, right:Dynamic):Dynamic {
		if (Std.isOfType(left, String) || Std.isOfType(right, String))
			return Std.string(left) + Std.string(right);
		if (bothInts(left, right)) {
			var first:Int = left, second:Int = right;
			return first + second;
		}
		return number(left) + number(right);
	}

	public static function sub(left:Dynamic, right:Dynamic):Float
		return number(left) - number(right);

	public static function mul(left:Dynamic, right:Dynamic):Float
		return number(left) * number(right);

	public static function div(left:Dynamic, right:Dynamic):Float
		return number(left) / number(right);

	public static function mod(left:Dynamic, right:Dynamic):Float
		return number(left) % number(right);

	public static function neg(value:Dynamic):Float
		return -number(value);

	public static function bitAnd(left:Dynamic, right:Dynamic):Int
		return integer(left) & integer(right);

	public static function bitOr(left:Dynamic, right:Dynamic):Int
		return integer(left) | integer(right);

	public static function bitXor(left:Dynamic, right:Dynamic):Int
		return integer(left) ^ integer(right);

	public static function shiftLeft(left:Dynamic, right:Dynamic):Int
		return integer(left) << integer(right);

	public static function shiftRight(left:Dynamic, right:Dynamic):Int
		return integer(left) >> integer(right);

	public static function unsignedShiftRight(left:Dynamic, right:Dynamic):Int
		return integer(left) >>> integer(right);

	/** What `Reflect.compare` returns for values that do not order: NaN, or kinds that cannot be compared. */
	static inline var UNORDERED = 0xAABBCCDD;

	/** `left < right`; values that do not order compare false, as for the typed operators. */
	public static function less(left:Dynamic, right:Dynamic):Bool {
		var order = Reflect.compare(left, right);
		return order != UNORDERED && order < 0;
	}

	public static function lessEqual(left:Dynamic, right:Dynamic):Bool {
		var order = Reflect.compare(left, right);
		return order != UNORDERED && order <= 0;
	}

	static function bothInts(left:Dynamic, right:Dynamic):Bool
		return Std.isOfType(left, Int) && Std.isOfType(right, Int);

	/** A boxed Int or Float as a Float. */
	static function number(value:Dynamic):Float {
		if (Std.isOfType(value, Int)) {
			var integer:Int = value;
			return integer;
		}
		if (Std.isOfType(value, Float)) {
			var float:Float = value;
			return float;
		}
		throw "Arithmetic on a Dynamic value that is not a number";
	}

	/** A boxed Int, or a Float truncated to one, as an Int. */
	static function integer(value:Dynamic):Int {
		if (Std.isOfType(value, Int)) {
			var integer:Int = value;
			return integer;
		}
		return Std.int(number(value));
	}
}
