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
		collectExceptionCellCandidates(statements, declared, exceptionCells);
		return {
			assigned: assigned,
			declared: declared,
			mutableCaptures: mutableCaptures,
			exceptionCells: exceptionCells
		};
	}

	public static function collectAssignedLocals(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch (statement) {
				case Assignment(name, _, _):
					if (name.indexOf(".") < 0)
						names.set(name, true);
				case Increment(name, _, _):
					names.set(name, true);
				case If(_, yes, no, _):
					collectAssignedLocals(yes, names);
					collectAssignedLocals(no, names);
				case While(_, body, _):
					collectAssignedLocals(body, names);
				case DoWhile(body, _, _):
					collectAssignedLocals(body, names);
				case ForIn(_, _, _, body, _):
					collectAssignedLocals(body, names);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						collectAssignedLocals(switchCase.statements, names);
					collectAssignedLocals(defaultBranch, names);
				case Try(tryBranch, catches, _):
					collectAssignedLocals(tryBranch, names);
					for (catchClause in catches)
						collectAssignedLocals(catchClause.statements, names);
				default:
			}
	}

	public static function collectDeclaredLocals(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
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

	public static function collectVariables(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case UninitializedDeclaration(_, _, _):
				case VarDeclaration(_, _, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectExpressionVariables(expression, names);
				case Assignment(name, expression, _):
					if (name.indexOf(".") < 0)
						names.set(name, true);
					collectExpressionVariables(expression, names);
				case IndexAssignment(array, offset, expression, _):
					collectExpressionVariables(array, names);
					collectExpressionVariables(offset, names);
					collectExpressionVariables(expression, names);
				case FieldAssignment(object, _, expression, _):
					collectExpressionVariables(object, names);
					collectExpressionVariables(expression, names);
				case ReturnVoid(_):
				case If(predicate, yes, no, _):
					collectExpressionVariables(predicate, names);
					collectVariables(yes, names);
					collectVariables(no, names);
				case While(predicate, body, _):
					collectExpressionVariables(predicate, names);
					collectVariables(body, names);
				case DoWhile(body, predicate, _):
					collectVariables(body, names);
					collectExpressionVariables(predicate, names);
				case ForIn(_, _, iterable, body, _):
					collectExpressionVariables(iterable, names);
					collectVariables(body, names);
				case Switch(expression, cases, defaultBranch, _, _):
					collectExpressionVariables(expression, names);
					for (switchCase in cases) {
						collectExpressionVariables(switchCase.value, names);
						var guard = switchCase.guard;
						if (guard != null)
							collectExpressionVariables(guard, names);
						collectVariables(switchCase.statements, names);
					}
					collectVariables(defaultBranch, names);
				case Try(tryBranch, catches, _):
					collectVariables(tryBranch, names);
					for (catchClause in catches)
						collectVariables(catchClause.statements, names);
				case Break(_), Continue(_):
				case Increment(name, _, _):
					names.set(name, true);
			}
	}

	public static function collectMutableCaptureCandidates(statements:Array<AstStatement>, outerDeclared:Map<String, Bool>, result:Map<String, Bool>):Void {
		for (statement in statements)
			switch (statement) {
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
		Locals mutated in a protected region and observed by its handler need stable
		storage: an exception can bypass SSA edge moves at any throwing instruction.
	**/
	public static function collectExceptionCellCandidates(statements:Array<AstStatement>, declared:Map<String, Bool>, result:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case Try(tryBranch, catches, _):
					var assigned:Map<String, Bool> = [],
						observed:Map<String, Bool> = [],
						protectedLocals:Map<String, Bool> = [],
						handlerLocals:Map<String, Bool> = [];
					collectAssignedLocals(tryBranch, assigned);
					collectDeclaredLocals(tryBranch, protectedLocals);
					for (name in protectedLocals.keys())
						assigned.remove(name);
					for (catchClause in catches) {
						collectVariables(catchClause.statements, observed);
						collectDeclaredLocals(catchClause.statements, handlerLocals);
					}
					for (name in handlerLocals.keys())
						observed.remove(name);
					for (name in observed.keys())
						if (assigned.exists(name) && declared.exists(name))
							result.set(name, true);
					collectExceptionCellCandidates(tryBranch, declared, result);
					for (catchClause in catches)
						collectExceptionCellCandidates(catchClause.statements, declared, result);
				case If(_, yes, no, _):
					collectExceptionCellCandidates(yes, declared, result);
					collectExceptionCellCandidates(no, declared, result);
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
					collectExceptionCellCandidates(body, declared, result);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						collectExceptionCellCandidates(switchCase.statements, declared, result);
					collectExceptionCellCandidates(defaultBranch, declared, result);
				default:
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
				NewMap(_, _, _):
		}

	public static function collectExpressionVariables(expression:AstExpression, names:Map<String, Bool>):Void
		switch expression {
			case Variable(name, _):
				names.set(name, true);
			case Member(object, _, _):
				collectExpressionVariables(object, names);
			case MethodCall(object, _, arguments, _):
				collectExpressionVariables(object, names);
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case Call(name, arguments, _):
				var separator = name.indexOf(".");
				if (separator > 0)
					names.set(compiler.QualifiedName.split(name)[0], true);
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _),
				Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _):
				collectExpressionVariables(left, names);
				collectExpressionVariables(right, names);
			case Negate(value, _):
				collectExpressionVariables(value, names);
			case Not(value, _):
				collectExpressionVariables(value, names);
			case And(left, right, _), Or(left, right, _):
				collectExpressionVariables(left, names);
				collectExpressionVariables(right, names);
			case Conditional(predicate, whenTrue, whenFalse, _):
				for (item in [predicate, whenTrue, whenFalse])
					collectExpressionVariables(item, names);
			case BlockExpression(statements, value, _):
				collectVariables(statements, names);
				collectExpressionVariables(value, names);
			case ThrowExpression(value, _):
				collectExpressionVariables(value, names);
			case Cast(value, _, _):
				collectExpressionVariables(value, names);
			case SwitchExpression(subject, cases, fallback, _):
				collectExpressionVariables(subject, names);
				for (switchCase in cases) {
					collectExpressionVariables(switchCase.value, names);
					var guard = switchCase.guard;
					if (guard != null)
						collectExpressionVariables(guard, names);
					collectExpressionVariables(switchCase.result, names);
				}
				var resolvedFallback = fallback;
				if (resolvedFallback != null)
					collectExpressionVariables(resolvedFallback, names);
			case ObjectLiteral(fields, _):
				for (field in fields)
					collectExpressionVariables(field.value, names);
			case ArrayLiteral(values, _):
				for (value in values)
					collectExpressionVariables(value, names);
			case MapLiteral(entries, _):
				for (entry in entries) {
					collectExpressionVariables(entry.key, names);
					collectExpressionVariables(entry.value, names);
				}
			case ArrayComprehension(_, _, iterable, predicate, value, _):
				collectExpressionVariables(iterable, names);
				if (predicate != null)
					collectExpressionVariables(predicate, names);
				collectExpressionVariables(value, names);
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				collectExpressionVariables(iterable, names);
				if (predicate != null)
					collectExpressionVariables(predicate, names);
				collectExpressionVariables(key, names);
				collectExpressionVariables(value, names);
			case Range(start, rangeEnd, _):
				collectExpressionVariables(start, names);
				collectExpressionVariables(rangeEnd, names);
			case New(_, arguments, _), NewGeneric(_, _, arguments, _):
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case NewArray(_, length, _):
				collectExpressionVariables(length, names);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				collectExpressionVariables(array, names);
				collectExpressionVariables(offset, names);
			case PostfixIncrement(target, _, _):
				collectExpressionVariables(target, names);
			case Lambda(_, body, _):
				collectVariables(body, names);
			case IntegerLiteral(_, _):
				return;
			case FloatLiteral(_, _):
				return;
			case StringLiteral(_, _):
				return;
			case BoolLiteral(_, _), NullLiteral(_), Unreachable(_):
				return;
		}
}
