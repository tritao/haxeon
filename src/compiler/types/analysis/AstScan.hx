package compiler.types.analysis;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/** Looks through every expression of a statement list, including nested bodies and lambdas, for one that passes a test. */
class AstScan {
	public static function anyExpression(statements:Array<AstStatement>, test:AstExpression->Bool):Bool {
		for (statement in statements)
			if (statementMatches(statement, test))
				return true;
		return false;
	}

	static function statementMatches(statement:AstStatement, test:AstExpression->Bool):Bool {
		for (expression in compiler.syntax.AstChildren.statementExpressions(statement))
			if (expressionMatches(expression, test))
				return true;
		return switch statement {
			case If(_, yes, no, _): anyExpression(yes, test) || anyExpression(no, test);
			case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _): anyExpression(body, test);
			case Try(tryBranch, catches, _):
				if (anyExpression(tryBranch, test))
					return true;
				for (caught in catches)
					if (anyExpression(caught.statements, test))
						return true;
				false;
			case Switch(_, cases, defaultBranch, _, _):
				for (entry in cases)
					if (anyExpression(entry.statements, test))
						return true;
				anyExpression(defaultBranch, test);
			default: false;
		};
	}

	static function expressionMatches(expression:AstExpression, test:AstExpression->Bool):Bool {
		if (test(expression))
			return true;
		switch expression {
			case BlockExpression(statements, value, _):
				return anyExpression(statements, test) || expressionMatches(value, test);
			case Lambda(_, body, _):
				return anyExpression(body, test);
			default:
		}
		for (child in compiler.syntax.AstChildren.expressions(expression))
			if (expressionMatches(child, test))
				return true;
		return false;
	}

	/** Whether a `break` in these statements leaves the loop they are the body of; breaks of nested loops are theirs. */
	public static function breaksOut(statements:Array<AstStatement>):Bool {
		for (statement in statements)
			switch statement {
				case Break(_):
					return true;
				case If(_, yes, no, _):
					if (breaksOut(yes) || breaksOut(no))
						return true;
				case Try(tryBranch, catches, _):
					if (breaksOut(tryBranch))
						return true;
					for (caught in catches)
						if (breaksOut(caught.statements))
							return true;
				case Switch(_, cases, defaultBranch, _, _):
					for (entry in cases)
						if (breaksOut(entry.statements))
							return true;
					if (breaksOut(defaultBranch))
						return true;
				default:
			}
		// A block expression is a statement list too; look for a break anywhere inside one to stay on the safe side.
		return anyExpression(statements, expression -> switch expression {
			case BlockExpression(inner, _, _): breaksOut(inner);
			default: false;
		});
	}

	/**
	 * Whether the statements call something named `remove` or `clear`, which may take entries out of a map. A removal of
	 * `visitedKey` itself is not counted when given: it only takes out the entry the loop is already past.
	 */
	public static function mayRemoveMapEntries(statements:Array<AstStatement>, ?visitedKey:String):Bool
		return anyExpression(statements, expression -> removesEntries(expression, visitedKey));

	static function removesEntries(expression:AstExpression, visitedKey:Null<String>):Bool
		return switch expression {
			case MethodCall(_, name, arguments, _): name == "remove" ? !isOnlyKey(arguments, visitedKey) : name == "clear";
			case Call(name, arguments, _):
				StringTools.endsWith(name, ".remove") ? !isOnlyKey(arguments, visitedKey) : StringTools.endsWith(name, ".clear");
			default: false;
		};

	static function isOnlyKey(arguments:Array<AstExpression>, key:Null<String>):Bool {
		if (key == null || arguments.length != 1)
			return false;
		return switch arguments[0] {
			case Variable(name, _): name == key;
			default: false;
		};
	}
}
