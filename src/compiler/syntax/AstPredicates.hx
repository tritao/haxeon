package compiler.syntax;

import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/** Small shared predicates over source expressions. */
class AstPredicates {
	/** Inspect a statement's structure without discarding its typing-time metadata. */
	public static function unannotatedStatement(value:AstStatement):AstStatement
		return switch value {
			case PrivateAccessStatement(inner, _): unannotatedStatement(inner);
			default: value;
		};

	/** Inspect an expression's structure without discarding its typing-time metadata. */
	public static function unannotatedExpression(value:AstExpression):AstExpression
		return switch value {
			case PrivateAccessExpression(inner, _): unannotatedExpression(inner);
			default: value;
		};

	public static function isNullExpression(value:Null<AstExpression>):Bool
		return switch value == null ? null : unannotatedExpression(value) {
			case null, NullLiteral(_): true;
			default: false;
		};

	/** Whether a call may omit `argument`: it is written `?x` or has a default value, as Haxe's optional flag. */
	public static function isOptionalArgument(argument:AstArgument):Bool
		return argument.optional == true || argument.defaultValue != null;

	/**
	 * Whether `argument`'s type is made nullable, by Haxe's rule: `?x:Int` and `?x:Int = 7` are `Null<Int>`, as is
	 * `x:Int = null`; `x:Int = 7` is `Int`.
	 */
	public static function isNullableArgument(argument:AstArgument):Bool
		return argument.optional == true || argument.defaultValue != null && isNullExpression(argument.defaultValue);
}
