package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.TypedExpression;

/** The value a `throw` throws. */
class ThrownValue {
	/**
	 * `value` as thrown: `throw null` throws a null Dynamic, as in Haxe, where a catch of Dynamic (or Any) binds null, a
	 * catch of haxe.Exception a ValueException of null, and a catch of any other type lets it through.
	 */
	public static function of(bodyTyper:BodyTyping, value:TypedExpression):TypedExpression
		return TypeRelations.equals(value.type, TNull) ? bodyTyper.coerce(value, TDynamic, "thrown value",
			"E1021") : value;
}
