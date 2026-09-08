package compiler.semantic;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/** Discovers compiler-generated lambda functions in canonical syntax trees. */
class LambdaCollector {
	public static function collect(statements:Array<AstStatement>, functionName:String, module:String, generatedByModule:Map<String, Map<String, Bool>>):Void {
		for (statement in statements)
			switch statement {
				case ErrorStatement(_):
				case UninitializedDeclaration(_, _, _):
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectExpression(expression, functionName, module, generatedByModule);
				case Try(tryBranch, catches, _):
					collect(tryBranch, functionName, module, generatedByModule);
					for (catchClause in catches)
						collect(catchClause.statements, functionName, module, generatedByModule);
				case IndexAssignment(array, offset, expression, _):
					collectLambdaExpression(array, functionName, module, generatedByModule);
					collectLambdaExpression(offset, functionName, module, generatedByModule);
					collectLambdaExpression(expression, functionName, module, generatedByModule);
				case FieldAssignment(object, _, expression, _):
					collectLambdaExpression(object, functionName, module, generatedByModule);
					collectLambdaExpression(expression, functionName, module, generatedByModule);
				case ReturnVoid(_):
				case Break(_), Continue(_):
				case Increment(_, _, _):
				case If(predicate, yes, no, _):
					collectLambdaExpression(predicate, functionName, module, generatedByModule);
					collect(yes, functionName, module, generatedByModule);
					collect(no, functionName, module, generatedByModule);
				case While(predicate, body, _):
					collectLambdaExpression(predicate, functionName, module, generatedByModule);
					collect(body, functionName, module, generatedByModule);
				case DoWhile(body, predicate, _):
					collect(body, functionName, module, generatedByModule);
					collectLambdaExpression(predicate, functionName, module, generatedByModule);
				case ForIn(_, _, iterable, body, _):
					collectLambdaExpression(iterable, functionName, module, generatedByModule);
					collect(body, functionName, module, generatedByModule);
				case Switch(expression, cases, defaultBranch, _, _):
					collectLambdaExpression(expression, functionName, module, generatedByModule);
					for (switchCase in cases) {
						collectLambdaExpression(switchCase.value, functionName, module, generatedByModule);
						var guard = switchCase.guard;
						if (guard != null)
							collectLambdaExpression(guard, functionName, module, generatedByModule);
						collect(switchCase.statements, functionName, module, generatedByModule);
					}
					collect(defaultBranch, functionName, module, generatedByModule);
			}
	}

	public static function collectExpression(expression:AstExpression, functionName:String, module:String,
			generatedByModule:Map<String, Map<String, Bool>>):Void
		switch expression {
			case Lambda(_, body, span):
				var names:Map<String, Bool>;
				if (generatedByModule.exists(module))
					names = generatedByModule.get(module);
				else {
					names = [];
					generatedByModule.set(module, names);
				}
				names.set('$' + 'lambda:' + functionName + ':' + Std.string(span.start), true);
				collect(body, functionName, module, generatedByModule);
			case Call(_, args, _):
				for (argument in args)
					collectLambdaExpression(argument, functionName, module, generatedByModule);
			case ClosureCall(callee, args, _):
				collectLambdaExpression(callee, functionName, module, generatedByModule);
				for (argument in args) collectLambdaExpression(argument, functionName, module, generatedByModule);
			case MethodCall(object, _, args, _):
				collectLambdaExpression(object, functionName, module, generatedByModule);
				for (argument in args)
					collectLambdaExpression(argument, functionName, module, generatedByModule);
			case Member(object, _, _):
				collectLambdaExpression(object, functionName, module, generatedByModule);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _),
				BitXor(left, right, _), BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _),
				Less(left, right, _), LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _),
				NotEqual(left, right, _):
				collectLambdaExpression(left, functionName, module, generatedByModule);
				collectLambdaExpression(right, functionName, module, generatedByModule);
			case Not(value, _):
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case Negate(value, _):
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case And(left, right, _), Or(left, right, _):
				collectLambdaExpression(left, functionName, module, generatedByModule);
				collectLambdaExpression(right, functionName, module, generatedByModule);
			case Conditional(predicate, whenTrue, whenFalse, _):
				collectLambdaExpression(predicate, functionName, module, generatedByModule);
				collectLambdaExpression(whenTrue, functionName, module, generatedByModule);
				collectLambdaExpression(whenFalse, functionName, module, generatedByModule);
			case BlockExpression(statements, value, _):
				collect(statements, functionName, module, generatedByModule);
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case ThrowExpression(value, _):
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case Cast(value, _, _):
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case SwitchExpression(subject, cases, fallback, _):
				collectLambdaExpression(subject, functionName, module, generatedByModule);
				for (switchCase in cases) {
					collectLambdaExpression(switchCase.value, functionName, module, generatedByModule);
					var guard = switchCase.guard;
					if (guard != null)
						collectLambdaExpression(guard, functionName, module, generatedByModule);
					collectLambdaExpression(switchCase.result, functionName, module, generatedByModule);
				}
				var fallbackExpression = fallback;
				if (fallbackExpression != null)
					collectLambdaExpression(fallbackExpression, functionName, module, generatedByModule);
			case ObjectLiteral(fields, _):
				for (field in fields)
					collectLambdaExpression(field.value, functionName, module, generatedByModule);
			case ArrayLiteral(values, _):
				for (value in values)
					collectLambdaExpression(value, functionName, module, generatedByModule);
			case MapLiteral(entries, _):
				for (mapEntry in entries) {
					collectLambdaExpression(mapEntry.key, functionName, module, generatedByModule);
					collectLambdaExpression(mapEntry.value, functionName, module, generatedByModule);
				}
			case ArrayComprehension(_, _, iterable, predicate, value, _):
				collectLambdaExpression(iterable, functionName, module, generatedByModule);
				if (predicate != null)
					collectLambdaExpression(predicate, functionName, module, generatedByModule);
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				collectLambdaExpression(iterable, functionName, module, generatedByModule);
				if (predicate != null)
					collectLambdaExpression(predicate, functionName, module, generatedByModule);
				collectLambdaExpression(key, functionName, module, generatedByModule);
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case Range(start, rangeEnd, _):
				collectLambdaExpression(start, functionName, module, generatedByModule);
				collectLambdaExpression(rangeEnd, functionName, module, generatedByModule);
			case New(_, args, _):
				for (argument in args)
					collectLambdaExpression(argument, functionName, module, generatedByModule);
			case NewArray(_, length, _):
				collectLambdaExpression(length, functionName, module, generatedByModule);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				collectLambdaExpression(array, functionName, module, generatedByModule);
				collectLambdaExpression(offset, functionName, module, generatedByModule);
			case PostfixIncrement(target, _, _):
				collectLambdaExpression(target, functionName, module, generatedByModule);
			default:
		}

	static inline function collectLambdaExpression(expression:AstExpression, functionName:String, module:String,
			generatedByModule:Map<String, Map<String, Bool>>):Void
		collectExpression(expression, functionName, module, generatedByModule);
}
