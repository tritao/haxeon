package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchCase;

/** Structural exit analysis for typed statement bodies. */
class ControlFlow {
	public static function isInfiniteLoop(condition:TypedExpression, body:Array<TypedStatement>):Bool
		return isTrueLiteral(condition) && !canBreakCurrentLoop(body);

	public static function alwaysReturns(statements:Array<TypedStatement>, exhaustive:(CompilerType, Array<TypedSwitchCase>) -> Bool):Bool
		return alwaysTerminates(statements, exhaustive, false);

	public static function alwaysExits(statements:Array<TypedStatement>, exhaustive:(CompilerType, Array<TypedSwitchCase>) -> Bool):Bool
		return alwaysTerminates(statements, exhaustive, true);

	static function alwaysTerminates(statements:Array<TypedStatement>, exhaustive:(CompilerType, Array<TypedSwitchCase>) -> Bool, loopExit:Bool):Bool {
		for (statement in statements)
			switch statement {
				case TReturn(_, _), TReturnVoid(_), TThrow(_, _):
					return true;
				case TBreak(_), TContinue(_) if (loopExit):
					return true;
				case TExpression(expression, _) if (expression.type == TNever):
					return true;
				case TIf(condition, yes, no, _):
					// A bare block `{ ... }` is an `if (true)` without an `else`: it always runs its body.
					if (isTrueLiteral(condition) ? alwaysTerminates(yes, exhaustive,
						loopExit) : no.length > 0 && alwaysTerminates(yes, exhaustive, loopExit) && alwaysTerminates(no, exhaustive, loopExit))
						return true;
				case TDoWhile(body, _, _):
					if (alwaysTerminates(body, exhaustive, loopExit))
						return true;
				case TWhile(condition, body, _) if (isInfiniteLoop(condition, body)):
					return true;
				case TTry(tryBranch, catches, _):
					if (alwaysTerminates(tryBranch, exhaustive, loopExit) && catches.length > 0 && [
						for (catchClause in catches)
							alwaysTerminates(catchClause.statements, exhaustive, loopExit)
					].indexOf(false) < 0)
						return true;
				case TSwitch(expression, cases, defaultBranch, hasDefault, _):
					if ((hasDefault ? alwaysTerminates(defaultBranch, exhaustive, loopExit) : hasCatchAllArm(cases) || exhaustive(expression.type, cases))
						&& [
							for (switchCase in cases)
								alwaysTerminates(switchCase.statements, exhaustive, loopExit)
						].indexOf(false) < 0)
						return true;
				default:
			}
		return false;
	}

	/** An arm without a guard that matches every value: the wildcard `case _:` or a bare name `case other:`. It is the default. */
	static function hasCatchAllArm(cases:Array<TypedSwitchCase>):Bool {
		for (switchCase in cases)
			if (switchCase.guard == null && (switchCase.isCatchAll || switchCase.subjectBinding != null))
				return true;
		return false;
	}

	static function isTrueLiteral(expression:TypedExpression):Bool
		return switch expression.expression {
			case TBoolLiteral(value): value;
			default: false;
		};

	static function canBreakCurrentLoop(statements:Array<TypedStatement>):Bool {
		for (statement in statements)
			switch statement {
				case TBreak(_):
					return true;
				case TIf(_, yes, no, _):
					if (canBreakCurrentLoop(yes) || canBreakCurrentLoop(no))
						return true;
				case TTry(tryBranch, catches, _):
					if (canBreakCurrentLoop(tryBranch))
						return true;
					for (catchClause in catches)
						if (canBreakCurrentLoop(catchClause.statements))
							return true;
				case TSwitch(_, cases, fallback, _, _):
					for (switchCase in cases)
						if (canBreakCurrentLoop(switchCase.statements))
							return true;
					if (canBreakCurrentLoop(fallback))
						return true;
				case TWhile(_, _, _), TDoWhile(_, _, _), TForIn(_, _, _, _, _):
				default:
			}
		return false;
	}
}
