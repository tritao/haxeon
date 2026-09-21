package compiler.syntax;

import compiler.syntax.Ast.AstExpression;

/** Small shared predicates over source expressions. */
class AstPredicates {
	public static function isNullExpression(value:Null<AstExpression>):Bool
		return switch value {
			case null, NullLiteral(_): true;
			default: false;
		};
}
