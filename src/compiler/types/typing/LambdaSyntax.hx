package compiler.types.typing;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

/** Looks through the parser's result-annotated lambda binding. */
class LambdaSyntax {
	public static function literal(expression:AstExpression):AstExpression {
		return switch expression {
			case BlockExpression(statements, Variable(name, _), _) if (statements.length == 1
				&& StringTools.startsWith(name, "$typedLambda")):
				switch statements[0] {
					case VarDeclaration(local, FunctionType(_, _), value, _) if (local == name): value;
					default: expression;
				}
			default: expression;
		};
	}
}
