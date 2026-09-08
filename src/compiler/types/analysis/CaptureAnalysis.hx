package compiler.types.analysis;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/** Storage requirements discovered from a function's source-level local usage. */
typedef BodyStorageAnalysis = {
	final assigned:Map<String, Bool>;
	final declared:Map<String, Bool>;
	final mutableCaptures:Map<String, Bool>;
	final exceptionCells:Map<String, Bool>;
}

/** Owns capture and exception-edge storage analysis independently of body typing. */
class CaptureAnalysis {
	public static function analyze(statements:Array<AstStatement>, arguments:Array<String>):BodyStorageAnalysis {
		var assigned:Map<String, Bool> = [],
			declared:Map<String, Bool> = [],
			mutableCaptures:Map<String, Bool> = [],
			exceptionCells:Map<String, Bool> = [];
		for (argument in arguments)
			declared.set(argument, true);
		collectAssignedLocals(statements, assigned);
		collectDeclaredLocals(statements, declared);
		collectMutableCaptureCandidates(statements, declared, mutableCaptures);
		collectExceptionCellCandidates(statements, [for (argument in arguments) argument => true], exceptionCells);
		return {
			assigned: assigned,
			declared: declared,
			mutableCaptures: mutableCaptures,
			exceptionCells: exceptionCells
		};
	}

	public static function collectAssignedLocals(statements:Array<AstStatement>, names:Map<String, Bool>):Void
		collectVariables(statements, names, true);

	public static function collectDeclaredLocals(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case ErrorStatement(_):
				case UninitializedDeclaration(name, _, _):
					names.set(name, true);
				case VarDeclaration(name, _, _, _):
					names.set(name, true);
				case If(_, yes, no, _):
					collectDeclaredLocals(yes, names);
					collectDeclaredLocals(no, names);
				case While(_, body, _):
					collectDeclaredLocals(body, names);
				case DoWhile(body, _, _):
					collectDeclaredLocals(body, names);
				case ForIn(name, valueName, _, body, _):
					names.set(name, true);
					if (valueName != null)
						names.set(valueName, true);
					collectDeclaredLocals(body, names);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						collectDeclaredLocals(switchCase.statements, names);
					collectDeclaredLocals(defaultBranch, names);
				case Try(tryBranch, catches, _):
					collectDeclaredLocals(tryBranch, names);
					for (catchClause in catches)
						collectDeclaredLocals(catchClause.statements, names);
				case Break(_), Continue(_):
				case Increment(_, _, _):
				default:
			}
	}

	public static function collectVariables(statements:Array<AstStatement>, names:Map<String, Bool>, writesOnly:Bool = false):Void {
		for (statement in statements)
			switch statement {
				case ErrorStatement(_):
				case UninitializedDeclaration(_, _, _):
				case VarDeclaration(_, _, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectExpressionVariables(expression, names, writesOnly);
				case Assignment(name, expression, _):
					if (!writesOnly || name.indexOf(".") < 0)
						names.set(pathRoot(name), true);
					collectExpressionVariables(expression, names, writesOnly);
				case IndexAssignment(array, offset, expression, _):
					collectExpressionVariables(array, names, writesOnly);
					collectExpressionVariables(offset, names, writesOnly);
					collectExpressionVariables(expression, names, writesOnly);
				case FieldAssignment(object, _, expression, _):
					collectExpressionVariables(object, names, writesOnly);
					collectExpressionVariables(expression, names, writesOnly);
				case ReturnVoid(_):
				case If(predicate, yes, no, _):
					collectExpressionVariables(predicate, names, writesOnly);
					collectVariables(yes, names, writesOnly);
					collectVariables(no, names, writesOnly);
				case While(predicate, body, _):
					collectExpressionVariables(predicate, names, writesOnly);
					collectVariables(body, names, writesOnly);
				case DoWhile(body, predicate, _):
					collectVariables(body, names, writesOnly);
					collectExpressionVariables(predicate, names, writesOnly);
				case ForIn(_, _, iterable, body, _):
					collectExpressionVariables(iterable, names, writesOnly);
					collectVariables(body, names, writesOnly);
				case Switch(expression, cases, defaultBranch, _, _):
					collectExpressionVariables(expression, names, writesOnly);
					for (switchCase in cases) {
						collectExpressionVariables(switchCase.value, names, writesOnly);
						var guard = switchCase.guard;
						if (guard != null)
							collectExpressionVariables(guard, names, writesOnly);
						collectVariables(switchCase.statements, names, writesOnly);
					}
					collectVariables(defaultBranch, names, writesOnly);
				case Try(tryBranch, catches, _):
					collectVariables(tryBranch, names, writesOnly);
					for (catchClause in catches)
						collectVariables(catchClause.statements, names, writesOnly);
				case Break(_), Continue(_):
				case Increment(name, _, _):
					if (!writesOnly || name.indexOf(".") < 0)
						names.set(pathRoot(name), true);
			}
	}

	public static function collectMutableCaptureCandidates(statements:Array<AstStatement>, outerDeclared:Map<String, Bool>, result:Map<String, Bool>):Void {
		for (statement in statements)
			switch (statement) {
				case ErrorStatement(_):
				case UninitializedDeclaration(_, _, _):
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectMutableCaptureExpression(expression, outerDeclared, result);
				case IndexAssignment(array, offset, expression, _):
					collectMutableCaptureExpression(array, outerDeclared, result);
					collectMutableCaptureExpression(offset, outerDeclared, result);
					collectMutableCaptureExpression(expression, outerDeclared, result);
				case FieldAssignment(object, _, expression, _):
					collectMutableCaptureExpression(object, outerDeclared, result);
					collectMutableCaptureExpression(expression, outerDeclared, result);
				case If(predicate, yes, no, _):
					collectMutableCaptureExpression(predicate, outerDeclared, result);
					collectMutableCaptureCandidates(yes, outerDeclared, result);
					collectMutableCaptureCandidates(no, outerDeclared, result);
				case While(predicate, body, _):
					collectMutableCaptureExpression(predicate, outerDeclared, result);
					collectMutableCaptureCandidates(body, outerDeclared, result);
				case DoWhile(body, predicate, _):
					collectMutableCaptureCandidates(body, outerDeclared, result);
					collectMutableCaptureExpression(predicate, outerDeclared, result);
				case ForIn(_, _, iterable, body, _):
					collectMutableCaptureExpression(iterable, outerDeclared, result);
					collectMutableCaptureCandidates(body, outerDeclared, result);
				case Switch(expression, cases, defaultBranch, _, _):
					collectMutableCaptureExpression(expression, outerDeclared, result);
					for (switchCase in cases) {
						collectMutableCaptureExpression(switchCase.value, outerDeclared, result);
						var guard = switchCase.guard;
						if (guard != null)
							collectMutableCaptureExpression(guard, outerDeclared, result);
						collectMutableCaptureCandidates(switchCase.statements, outerDeclared, result);
					}
					collectMutableCaptureCandidates(defaultBranch, outerDeclared, result);
				case Try(tryBranch, catches, _):
					collectMutableCaptureCandidates(tryBranch, outerDeclared, result);
					for (catchClause in catches)
						collectMutableCaptureCandidates(catchClause.statements, outerDeclared, result);
				case ReturnVoid(_), Break(_), Continue(_), Increment(_, _, _):
			}
	}

	/**
		Conservatively keep outer locals written in a protected region in stable
		storage, including values observed only after the handler returns. Names
		here are candidates; the typer allocates cells per resolved binding ID.
	**/
	public static function collectExceptionCellCandidates(statements:Array<AstStatement>, outer:Map<String, Bool>, result:Map<String, Bool>):Void {
		var visible:Map<String, Bool> = [for (name in outer.keys()) name => true];
		for (statement in statements) {
			for (expression in compiler.syntax.AstChildren.statementExpressions(statement))
				collectExceptionExpression(expression, visible, result);
			switch statement {
				case VarDeclaration(name, _, _, _), UninitializedDeclaration(name, _, _):
					visible.set(name, true);
				case Try(tryBranch, catches, _):
					var assigned:Map<String, Bool> = [];
					collectAssignedLocals(tryBranch, assigned);
					for (name in assigned.keys())
						if (visible.exists(name))
							result.set(name, true);
					collectExceptionCellCandidates(tryBranch, visible, result);
					for (catchClause in catches) {
						var caught:Map<String, Bool> = [for (name in visible.keys()) name => true];
						caught.set(catchClause.name, true);
						collectExceptionCellCandidates(catchClause.statements, caught, result);
					}
				case If(_, yes, no, _):
					collectExceptionCellCandidates(yes, visible, result);
					collectExceptionCellCandidates(no, visible, result);
				case While(_, body, _), DoWhile(body, _, _):
					collectExceptionCellCandidates(body, visible, result);
				case ForIn(key, value, _, body, _):
					var loop:Map<String, Bool> = [for (name in visible.keys()) name => true];
					loop.set(key, true);
					if (value != null)
						loop.set(value, true);
					collectExceptionCellCandidates(body, loop, result);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases) {
						var arm:Map<String, Bool> = [for (name in visible.keys()) name => true];
						collectExpressionVariables(switchCase.value, arm);
						collectExceptionCellCandidates(switchCase.statements, arm, result);
					}
					collectExceptionCellCandidates(defaultBranch, visible, result);
				default:
			}
		}
	}

	static function collectExceptionExpression(expression:AstExpression, visible:Map<String, Bool>, result:Map<String, Bool>):Void {
		switch expression {
			case BlockExpression(statements, value, _):
				collectExceptionCellCandidates(statements, visible, result);
				var inner:Map<String, Bool> = [for (name in visible.keys()) name => true];
				for (statement in statements)
					switch statement {
						case VarDeclaration(name, _, _, _), UninitializedDeclaration(name, _, _): inner.set(name, true);
						default:
					}
				collectExceptionExpression(value, inner, result);
			default:
				for (child in compiler.syntax.AstChildren.expressions(expression))
					collectExceptionExpression(child, visible, result);
		}
	}

	public static function collectMutableCaptureExpression(expression:AstExpression, outerDeclared:Map<String, Bool>, result:Map<String, Bool>):Void
		switch (expression) {
			case Lambda(arguments, body, _):
				var declared:Map<String, Bool> = [];
				for (argument in arguments)
					declared.set(argument.name, true);
				collectDeclaredLocals(body, declared);
				var names:Map<String, Bool> = [],
					assigned:Map<String, Bool> = [];
				collectVariables(body, names);
				collectAssignedLocals(body, assigned);
				for (name in assigned.keys())
					names.set(name, true);
				for (name in names.keys())
					if (!declared.exists(name) && outerDeclared.exists(name))
						result.set(name, true);
				collectMutableCaptureCandidates(body, outerDeclared, result);
			case Member(object, _, _):
				collectMutableCaptureExpression(object, outerDeclared, result);
			case MethodCall(object, _, arguments, _):
				collectMutableCaptureExpression(object, outerDeclared, result);
				for (argument in arguments)
					collectMutableCaptureExpression(argument, outerDeclared, result);
			case Call(_, arguments, _):
				for (argument in arguments)
					collectMutableCaptureExpression(argument, outerDeclared, result);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _),
				Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _), And(left, right, _), Or(left, right, _):
				collectMutableCaptureExpression(left, outerDeclared, result);
				collectMutableCaptureExpression(right, outerDeclared, result);
			case Negate(value, _), Not(value, _):
				collectMutableCaptureExpression(value, outerDeclared, result);
			case New(_, arguments, _), NewGeneric(_, _, arguments, _):
				for (argument in arguments)
					collectMutableCaptureExpression(argument, outerDeclared, result);
			case NewArray(_, length, _):
				collectMutableCaptureExpression(length, outerDeclared, result);
			case Index(array, offset, _):
				collectMutableCaptureExpression(array, outerDeclared, result);
				collectMutableCaptureExpression(offset, outerDeclared, result);
			case PostfixIncrement(target, _, _):
				collectMutableCaptureExpression(target, outerDeclared, result);
			case Conditional(predicate, whenTrue, whenFalse, _):
				for (item in [predicate, whenTrue, whenFalse])
					collectMutableCaptureExpression(item, outerDeclared, result);
			case BlockExpression(statements, value, _):
				collectMutableCaptureCandidates(statements, outerDeclared, result);
				collectMutableCaptureExpression(value, outerDeclared, result);
			case ThrowExpression(value, _):
				collectMutableCaptureExpression(value, outerDeclared, result);
			case Cast(value, _, _):
				collectMutableCaptureExpression(value, outerDeclared, result);
			case SwitchExpression(subject, cases, fallback, _):
				collectMutableCaptureExpression(subject, outerDeclared, result);
				for (switchCase in cases) {
					collectMutableCaptureExpression(switchCase.value, outerDeclared, result);
					var guard = switchCase.guard;
					if (guard != null)
						collectMutableCaptureExpression(guard, outerDeclared, result);
					collectMutableCaptureExpression(switchCase.result, outerDeclared, result);
				}
				var resolvedFallback = fallback;
				if (resolvedFallback != null)
					collectMutableCaptureExpression(resolvedFallback, outerDeclared, result);
			case ObjectLiteral(fields, _):
				for (field in fields)
					collectMutableCaptureExpression(field.value, outerDeclared, result);
			case ArrayLiteral(values, _):
				for (value in values)
					collectMutableCaptureExpression(value, outerDeclared, result);
			case MapLiteral(entries, _):
				for (entry in entries) {
					collectMutableCaptureExpression(entry.key, outerDeclared, result);
					collectMutableCaptureExpression(entry.value, outerDeclared, result);
				}
			case ArrayComprehension(_, _, iterable, predicate, value, _):
				collectMutableCaptureExpression(iterable, outerDeclared, result);
				if (predicate != null)
					collectMutableCaptureExpression(predicate, outerDeclared, result);
				collectMutableCaptureExpression(value, outerDeclared, result);
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				collectMutableCaptureExpression(iterable, outerDeclared, result);
				if (predicate != null)
					collectMutableCaptureExpression(predicate, outerDeclared, result);
				collectMutableCaptureExpression(key, outerDeclared, result);
				collectMutableCaptureExpression(value, outerDeclared, result);
			case Range(start, rangeEnd, _):
				collectMutableCaptureExpression(start, outerDeclared, result);
				collectMutableCaptureExpression(rangeEnd, outerDeclared, result);
			case Variable(_, _), IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_),
				ErrorExpression(_), NewMap(_, _, _):
		}

	public static function collectExpressionVariables(expression:AstExpression, names:Map<String, Bool>, writesOnly:Bool = false):Void
		switch expression {
			case Variable(name, _):
				if (!writesOnly)
					names.set(pathRoot(name), true);
			case Member(object, _, _):
				collectExpressionVariables(object, names, writesOnly);
			case MethodCall(object, _, arguments, _):
				collectExpressionVariables(object, names, writesOnly);
				for (argument in arguments)
					collectExpressionVariables(argument, names, writesOnly);
			case Call(name, arguments, _):
				if (!writesOnly)
					names.set(pathRoot(name), true);
				for (argument in arguments)
					collectExpressionVariables(argument, names, writesOnly);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _),
				Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _):
				collectExpressionVariables(left, names, writesOnly);
				collectExpressionVariables(right, names, writesOnly);
			case Negate(value, _):
				collectExpressionVariables(value, names, writesOnly);
			case Not(value, _):
				collectExpressionVariables(value, names, writesOnly);
			case And(left, right, _), Or(left, right, _):
				collectExpressionVariables(left, names, writesOnly);
				collectExpressionVariables(right, names, writesOnly);
			case Conditional(predicate, whenTrue, whenFalse, _):
				for (item in [predicate, whenTrue, whenFalse])
					collectExpressionVariables(item, names, writesOnly);
			case BlockExpression(statements, value, _):
				collectVariables(statements, names, writesOnly);
				collectExpressionVariables(value, names, writesOnly);
			case ThrowExpression(value, _):
				collectExpressionVariables(value, names, writesOnly);
			case Cast(value, _, _):
				collectExpressionVariables(value, names, writesOnly);
			case SwitchExpression(subject, cases, fallback, _):
				collectExpressionVariables(subject, names, writesOnly);
				for (switchCase in cases) {
					collectExpressionVariables(switchCase.value, names, writesOnly);
					var guard = switchCase.guard;
					if (guard != null)
						collectExpressionVariables(guard, names, writesOnly);
					collectExpressionVariables(switchCase.result, names, writesOnly);
				}
				var resolvedFallback = fallback;
				if (resolvedFallback != null)
					collectExpressionVariables(resolvedFallback, names, writesOnly);
			case ObjectLiteral(fields, _):
				for (field in fields)
					collectExpressionVariables(field.value, names, writesOnly);
			case ArrayLiteral(values, _):
				for (value in values)
					collectExpressionVariables(value, names, writesOnly);
			case MapLiteral(entries, _):
				for (entry in entries) {
					collectExpressionVariables(entry.key, names, writesOnly);
					collectExpressionVariables(entry.value, names, writesOnly);
				}
			case ArrayComprehension(_, _, iterable, predicate, value, _):
				collectExpressionVariables(iterable, names, writesOnly);
				if (predicate != null)
					collectExpressionVariables(predicate, names, writesOnly);
				collectExpressionVariables(value, names, writesOnly);
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				collectExpressionVariables(iterable, names, writesOnly);
				if (predicate != null)
					collectExpressionVariables(predicate, names, writesOnly);
				collectExpressionVariables(key, names, writesOnly);
				collectExpressionVariables(value, names, writesOnly);
			case Range(start, rangeEnd, _):
				collectExpressionVariables(start, names, writesOnly);
				collectExpressionVariables(rangeEnd, names, writesOnly);
			case New(_, arguments, _), NewGeneric(_, _, arguments, _):
				for (argument in arguments)
					collectExpressionVariables(argument, names, writesOnly);
			case NewArray(_, length, _):
				collectExpressionVariables(length, names, writesOnly);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				collectExpressionVariables(array, names, writesOnly);
				collectExpressionVariables(offset, names, writesOnly);
			case PostfixIncrement(target, _, _):
				switch target {
					case Variable(name, _) if (writesOnly && name.indexOf(".") < 0): names.set(name, true);
					default: collectExpressionVariables(target, names, writesOnly);
				}
			case Lambda(_, body, _):
				if (!writesOnly)
					collectVariables(body, names);
			case IntegerLiteral(_, _):
				return;
			case FloatLiteral(_, _):
				return;
			case StringLiteral(_, _):
				return;
			case BoolLiteral(_, _), NullLiteral(_), Unreachable(_), ErrorExpression(_):
				return;
		}

	static function pathRoot(name:String):String {
		var separator = name.indexOf(".");
		return separator < 0 ? name : name.substring(0, separator);
	}
}
