package compiler.syntax;

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
}
