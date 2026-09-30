package compiler.types.analysis;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/**
 * Names assigned in a statement list, by name. Storage requirements are decided per declaration by
 * `LexicalStorageAnalysis`; this stays name-based because its consumers only need a conservative "may be assigned".
 */
class CaptureAnalysis {
	public static function collectAssignedLocals(statements:Array<AstStatement>, names:Map<String, Bool>):Void
		collectVariables(statements, names, true);

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
			case ClosureCall(callee, arguments, _):
				collectExpressionVariables(callee, names, writesOnly);
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
			case And(left, right, _):
				collectLogicalVariables(left, right, true, names, writesOnly);
			case Or(left, right, _):
				collectLogicalVariables(left, right, false, names, writesOnly);
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
			case ArrayComprehension(_, _, iterable, predicate, value, _, _):
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
			case BoolLiteral(_, _), NullLiteral(_), Unreachable(_), EmptyExpression(_), ErrorExpression(_), NativeLayoutQuery(_, _, _, _):
				return;
		}

	static function collectLogicalVariables(left:AstExpression, right:AstExpression, and:Bool, names:Map<String, Bool>, writesOnly:Bool):Void {
		var pending:Array<AstExpression> = [right, left];
		while (pending.length > 0) {
			var current:AstExpression = cast pending.pop();
			switch current {
				case And(nestedLeft, nestedRight, _) if (and):
					pending.push(nestedRight);
					pending.push(nestedLeft);
				case Or(nestedLeft, nestedRight, _) if (!and):
					pending.push(nestedRight);
					pending.push(nestedLeft);
				default:
					collectExpressionVariables(current, names, writesOnly);
			}
		}
	}

	static function pathRoot(name:String):String {
		var separator = name.indexOf(".");
		return separator < 0 ? name : name.substring(0, separator);
	}
}
