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
	public static function breaksOut(statements:Array<AstStatement>):Bool
		return jumpsOut(statements, statement -> switch statement {
			case Break(_): true;
			default: false;
		});

	/** Whether a `continue` in these statements restarts the loop they are the body of; continues of nested loops are theirs. */
	public static function continuesOut(statements:Array<AstStatement>):Bool
		return jumpsOut(statements, statement -> switch statement {
			case Continue(_): true;
			default: false;
		});

	static function jumpsOut(statements:Array<AstStatement>, isJump:AstStatement->Bool):Bool {
		for (statement in statements) {
			if (isJump(statement))
				return true;
			switch statement {
				case If(_, yes, no, _):
					if (jumpsOut(yes, isJump) || jumpsOut(no, isJump))
						return true;
				case Try(tryBranch, catches, _):
					if (jumpsOut(tryBranch, isJump))
						return true;
					for (caught in catches)
						if (jumpsOut(caught.statements, isJump))
							return true;
				case Switch(_, cases, defaultBranch, _, _):
					for (entry in cases)
						if (jumpsOut(entry.statements, isJump))
							return true;
					if (jumpsOut(defaultBranch, isJump))
						return true;
				default:
			}
		}
		// A block expression is a statement list too; look for the jump anywhere inside one to stay on the safe side.
		return anyExpression(statements, expression -> switch expression {
			case BlockExpression(inner, _, _): jumpsOut(inner, isJump);
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
