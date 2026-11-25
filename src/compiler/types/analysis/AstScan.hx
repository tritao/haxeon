package compiler.types.analysis;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.AstChildren;

/** Looks through every expression of a statement list, including nested bodies and lambdas, for one that passes a test. */
class AstScan {
	public static function anyExpression(statements:Array<AstStatement>, test:AstExpression->Bool):Bool
		return new ExpressionSearch(test).inStatements(statements);

	/** Whether a `return` in these statements returns from the function they belong to; a lambda's returns are its own. */
	public static function returns(statements:Array<AstStatement>):Bool
		return returnsFrom(statements, false);

	/** Whether a `return` of a value in these statements returns from the function they belong to (`returns`). */
	public static function returnsValue(statements:Array<AstStatement>):Bool
		return returnsFrom(statements, true);

	static function returnsFrom(statements:Array<AstStatement>, valueOnly:Bool):Bool {
		for (statement in statements) {
			switch statement {
				case Return(_, _):
					return true;
				case ReturnVoid(_):
					if (!valueOnly)
						return true;
				case AnnotatedStatement(_, inner, _):
					if (returnsFrom([inner], valueOnly))
						return true;
				case If(_, yes, no, _):
					if (returnsFrom(yes, valueOnly) || returnsFrom(no, valueOnly))
						return true;
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _), Defer(body, _):
					if (returnsFrom(body, valueOnly))
						return true;
				case Try(tryBranch, catches, _):
					if (returnsFrom(tryBranch, valueOnly))
						return true;
					for (caught in catches)
						if (returnsFrom(caught.statements, valueOnly))
							return true;
				case Switch(_, cases, defaultBranch, _, _):
					for (entry in cases)
						if (returnsFrom(entry.statements, valueOnly))
							return true;
					if (returnsFrom(defaultBranch, valueOnly))
						return true;
				default:
			}
			for (expression in compiler.syntax.AstChildren.statementExpressions(statement))
				if (expressionReturns(expression, valueOnly))
					return true;
		}
		return false;
	}

	static function expressionReturns(expression:AstExpression, valueOnly:Bool):Bool {
		switch expression {
			case BlockExpression(statements, value, _):
				return returnsFrom(statements, valueOnly) || expressionReturns(value, valueOnly);
			case Lambda(_, _, _, _):
				return false;
			default:
		}
		for (child in compiler.syntax.AstChildren.expressions(expression))
			if (expressionReturns(child, valueOnly))
				return true;
		return false;
	}

	/** Whether a `break` in these statements leaves the loop they are the body of; breaks of nested loops are theirs. */
	public static function breaksOut(statements:Array<AstStatement>):Bool
		return jumpsOut(statements, statement -> switch statement {
			case Break(_): true;
			default: false;
		}, expression -> switch expression {
			case BreakExpression(_): true;
			default: false;
		});

	/** Whether a `continue` in these statements restarts the loop they are the body of; continues of nested loops are theirs. */
	public static function continuesOut(statements:Array<AstStatement>):Bool
		return jumpsOut(statements, statement -> switch statement {
			case Continue(_): true;
			default: false;
		}, expression -> switch expression {
			case ContinueExpression(_): true;
			default: false;
		});

	static function jumpsOut(statements:Array<AstStatement>, isJump:AstStatement->Bool,
			isJumpExpression:AstExpression->Bool):Bool {
		for (statement in statements) {
			if (isJump(statement))
				return true;
			switch statement {
				case AnnotatedStatement(_, inner, _):
					if (jumpsOut([inner], isJump, isJumpExpression))
						return true;
				case If(_, yes, no, _):
					if (jumpsOut(yes, isJump, isJumpExpression) || jumpsOut(no, isJump, isJumpExpression))
						return true;
				case Try(tryBranch, catches, _):
					if (jumpsOut(tryBranch, isJump, isJumpExpression))
						return true;
					for (caught in catches)
						if (jumpsOut(caught.statements, isJump, isJumpExpression))
							return true;
				case Switch(_, cases, defaultBranch, _, _):
					for (entry in cases)
						if (jumpsOut(entry.statements, isJump, isJumpExpression))
							return true;
					if (jumpsOut(defaultBranch, isJump, isJumpExpression))
						return true;
				default:
			}
		}
		// A block expression is a statement list too, and a jump can be an expression (`if (done) break else next()`); look
		// for one anywhere inside to stay on the safe side.
		return anyExpression(statements, expression -> isJumpExpression(expression) || switch expression {
			case BlockExpression(inner, _, _): jumpsOut(inner, isJump, isJumpExpression);
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
			case MethodCall(_, name, arguments, _): name == "remove" ? !isOnlyKey(arguments, visitedKey) : name
				== "clear";
			case Call(name, arguments, _):
				StringTools.endsWith(name, ".remove") ? !isOnlyKey(arguments, visitedKey) : StringTools.endsWith(name,
					".clear");
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

/**
 * One `AstScan.anyExpression` search: walks the children through `AstChildren`'s visitor rather than its arrays, which
 * every node of a scanned body would allocate, and stops testing once an expression has passed.
 */
private class ExpressionSearch implements AstChildVisitor {
	final test:AstExpression->Bool;
	var found = false;

	public function new(test:AstExpression->Bool)
		this.test = test;

	public function inStatements(statements:Array<AstStatement>):Bool {
		for (statement in statements)
			if (inStatement(statement))
				return true;
		return false;
	}

	function inStatement(statement:AstStatement):Bool {
		AstChildren.visitStatement(statement, this);
		if (found)
			return true;
		return switch statement {
			case AnnotatedStatement(_, inner, _): inStatement(inner);
			case If(_, yes, no, _): inStatements(yes) || inStatements(no);
			case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _): inStatements(body);
			case Defer(body, _): inStatements(body);
			case Try(tryBranch, catches, _):
				if (inStatements(tryBranch))
					return true;
				for (caught in catches)
					if (inStatements(caught.statements))
						return true;
				false;
			case Switch(_, cases, defaultBranch, _, _):
				for (entry in cases)
					if (inStatements(entry.statements))
						return true;
				inStatements(defaultBranch);
			default: false;
		};
	}

	public function visitChild(child:AstExpression):Void
		if (!found && inExpression(child))
			found = true;

	function inExpression(expression:AstExpression):Bool {
		if (test(expression))
			return true;
		switch expression {
			case BlockExpression(statements, value, _):
				return inStatements(statements) || inExpression(value);
			case Lambda(_, body, _, _):
				return inStatements(body);
			default:
		}
		AstChildren.visit(expression, this);
		return found;
	}
}
