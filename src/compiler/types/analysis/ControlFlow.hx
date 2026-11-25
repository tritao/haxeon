package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedChildren;

/** Structural exit analysis for typed statement bodies. */
class ControlFlow {
	/**
	 * Whether the else of an `if` can run. A bare block `{ ... }` is an `if (true)` without an else (the parser lowers it so), so
	 * its body always runs and no path skips it. The one rule for flow merges and for the exit analysis. As in C# and Java, a constant
	 * true condition is definitely taken for definite assignment (`if (true) x = 1;` assigns x), a constant false one is not.
	 */
	public static function elseCanRun(condition:TypedExpression):Bool
		return !isTrueLiteral(condition);

	public static function isInfiniteLoop(condition:TypedExpression, body:Array<TypedStatement>):Bool
		return isTrueLiteral(condition) && !canBreakCurrentLoop(body);

	/**
	 * Whether the statements certainly return or throw. Code after such statements is reported as unreachable, so this
	 * recognises only the forms that rule has always been written against; an infinite loop is not one of them.
	 */
	public static function alwaysReturns(statements:Array<TypedStatement>,
			exhaustive:(CompilerType, Array<TypedSwitchCase>) -> Bool):Bool
		return alwaysTerminates(statements, exhaustive, false, false);

	/**
	 * Whether a body returns on every path, for the missing-return check. As in Haxe, a switch ending in the wildcard
	 * arm `case _:` has a default and a bare block runs its body, which `alwaysReturns` does not count: dead code after
	 * one of them has always been accepted.
	 */
	public static function returnsOnEveryPath(statements:Array<TypedStatement>,
			exhaustive:(CompilerType, Array<TypedSwitchCase>) -> Bool):Bool
		return alwaysTerminates(statements, exhaustive, false, true);

	public static function alwaysExits(statements:Array<TypedStatement>,
			exhaustive:(CompilerType, Array<TypedSwitchCase>) -> Bool):Bool
		return alwaysTerminates(statements, exhaustive, true, false);

	static function alwaysTerminates(statements:Array<TypedStatement>,
			exhaustive:(CompilerType, Array<TypedSwitchCase>) -> Bool, loopExit:Bool,
			complete:Bool):Bool {
		for (statement in statements)
			switch statement {
				case TReturn(_, _), TReturnVoid(_), TThrow(_, _):
					return true;
				case TBreak(_), TContinue(_) if (loopExit):
					return true;
				case TExpression(expression, _) if ((switch (expression.type) {
					case TNever: true;
					default: false;
				})): return true;
				case TIf(condition, yes, no, _):
					// A bare block always runs its body. `alwaysReturns`, the unreachable-code rule, still does not count it: dead code after
					// one has always been accepted.
					if ((complete || loopExit) && !elseCanRun(condition)) {
						if (alwaysTerminates(yes, exhaustive, loopExit, complete))
							return true;
					} else if (no.length > 0
						&& alwaysTerminates(yes, exhaustive, loopExit, complete)
						&& alwaysTerminates(no, exhaustive, loopExit, complete))
						return true;
				case TDoWhile(body, _, _):
					if (alwaysTerminates(body, exhaustive, loopExit, complete))
						return true;
				// As in Haxe, code after `while (true)` that only leaves by returning is accepted, so the unreachable-code rule
				// (`alwaysReturns`) does not count the loop; the missing-return check does.
				case TWhile(condition, body, _) if ((loopExit || complete) && isInfiniteLoop(condition, body)):
					return true;
				case TTry(tryBranch, catches, _):
					if (alwaysTerminates(tryBranch, exhaustive, loopExit, complete) && catches.length > 0 && [
						for (catchClause in catches)
							alwaysTerminates(catchClause.statements, exhaustive, loopExit, complete)
					].indexOf(false) < 0)
						return true;
				case TSwitch(expression, cases, defaultBranch, hasDefault, _):
					// A tuple switch without a default was typed only once its arms cover every tuple.
					var covered = hasDefault ? alwaysTerminates(defaultBranch, exhaustive, loopExit,
						complete) : (complete && hasCatchAllArm(cases)) || isTuple(expression)
						|| exhaustive(expression.type, cases);
					if (covered && [
						for (switchCase in cases)
							alwaysTerminates(switchCase.statements, exhaustive, loopExit, complete)
					].indexOf(false) < 0)
						return true;
				default:
			}
		return false;
	}

	/** An arm without a guard that matches every value: the wildcard `case _:` or a bare name `case other:`. It is the default. */
	static function hasCatchAllArm(cases:Array<TypedSwitchCase>):Bool {
		for (switchCase in cases)
			for (arm in switchCase.arms)
				if (arm.guard == null && arm.isCatchAll)
					return true;
		return false;
	}

	static function isTuple(expression:TypedExpression):Bool
		return switch expression.expression {
			case TTuple(_): true;
			default: false;
		};

	static function isTrueLiteral(expression:TypedExpression):Bool
		return switch expression.expression {
			case TBoolLiteral(value): value;
			default: false;
		};

	static function canBreakCurrentLoop(statements:Array<TypedStatement>):Bool {
		var breaks = false;
		for (statement in statements)
			switch statement {
				case TBreak(_):
					return true;
				// A nested loop's breaks are its own.
				case TWhile(_, _, _), TDoWhile(_, _, _), TForIn(_, _, _, _, _):
				default:
					// Branches' statements, and `break` as an expression, as in `var x = if (done) break else next()`.
					TypedChildren.ofStatement(statement,
						expression -> if (!breaks && containsLoopJump(expression)) breaks = true,
						nested -> if (!breaks && canBreakCurrentLoop(nested)) breaks = true);
					if (breaks)
						return true;
			}
		return false;
	}

	/**
	 * Whether `expression` holds a `break` or `continue`, as a statement or an expression, outside any lambda: one of a loop
	 * nested in it counts too, so a caller that needs certainty only learns that the expression may jump.
	 */
	public static function containsLoopJump(expression:TypedExpression):Bool {
		var found = false;
		var statements:Array<TypedStatement>->Void = null;
		function visit(child:TypedExpression):Void {
			if (found)
				return;
			switch child.expression {
				case TBreakExpression, TContinueExpression: found = true;
				case kind: TypedChildren.ofExpression(kind, visit, statements);
			}
		}
		statements = function(list:Array<TypedStatement>):Void {
			for (statement in list) {
				if (found)
					return;
				switch statement {
					case TBreak(_), TContinue(_): found = true;
					case _: TypedChildren.ofStatement(statement, visit, statements);
				}
			}
		};
		visit(expression);
		return found;
	}
}
