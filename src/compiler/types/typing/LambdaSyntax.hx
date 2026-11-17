package compiler.types.typing;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

/** Looks through the parser's result-annotated lambda binding. */
class LambdaSyntax {
	public static function literal(expression:AstExpression):AstExpression {
		var syntax = compiler.syntax.AstPredicates.unannotatedExpression(expression),
			result = annotated(syntax);
		return result == null ? syntax : result;
	}

	/** Return the wrapped lambda only when the parser made an annotated binding. */
	public static function annotated(expression:AstExpression):Null<AstExpression> {
		return switch expression {
			case BlockExpression(statements, Variable(name, _), _) if (statements.length == 1
				&& StringTools.startsWith(name, "$typedLambda")):
				switch statements[0] {
					case VarDeclaration(local, FunctionType(_, _, _), value, _) if (local == name): value;
					default: null;
				}
			default: null;
		};
	}
}
