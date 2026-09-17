package compiler.semantic;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.AstChildren;

/** Collects qualified source dependencies referenced by syntax trees. */
class DependencyScanner {
	public static function scanStatement(s:AstStatement, dependencies:Map<String, Bool>):Void
		switch s {
			case ErrorStatement(_):
			case UninitializedDeclaration(_, type, _):
				scanType(type, dependencies);
			case VarDeclaration(_, type, e, _):
				if (type != null)
					scanType(type, dependencies);
				scanExpression(e, dependencies);
			case Assignment(_, e, _), Return(e, _), Throw(e, _):
				scanExpression(e, dependencies);
			case Try(tryBranch, catches, _):
				for (x in tryBranch)
					scanStatement(x, dependencies);
				for (catchClause in catches) {
					scanType(catchClause.type, dependencies);
					for (x in catchClause.statements)
						scanStatement(x, dependencies);
				}
			case IndexAssignment(array, offset, e, _):
				scanExpression(array, dependencies);
				scanExpression(offset, dependencies);
				scanExpression(e, dependencies);
			case FieldAssignment(object, _, e, _):
				scanExpression(object, dependencies);
				scanExpression(e, dependencies);
			case ReturnVoid(_):
			case Break(_), Continue(_):
			case Increment(_, _, _):
			case If(c, y, n, _):
				scanExpression(c, dependencies);
				for (x in y)
					scanStatement(x, dependencies);
				for (x in n)
					scanStatement(x, dependencies);
			case While(c, b, _):
				scanExpression(c, dependencies);
				for (x in b)
					scanStatement(x, dependencies);
			case DoWhile(b, c, _):
				for (x in b)
					scanStatement(x, dependencies);
				scanExpression(c, dependencies);
			case ForIn(_, _, iterable, b, _):
				scanExpression(iterable, dependencies);
				for (x in b)
					scanStatement(x, dependencies);
			case Switch(expression, cases, defaultBranch, _, _):
				scanExpression(expression, dependencies);
				for (switchCase in cases) {
					scanExpression(switchCase.value, dependencies);
					var guard = switchCase.guard;
					if (guard != null)
						scanExpression(guard, dependencies);
					for (x in switchCase.statements)
						scanStatement(x, dependencies);
				}
				for (x in defaultBranch)
					scanStatement(x, dependencies);
			case Expression(e, _):
				scanExpression(e, dependencies);
		}

	public static function scanExpression(e:AstExpression, dependencies:Map<String, Bool>):Void
		switch e {
			case Add(a, b, _):
				scanExpression(a, dependencies);
				scanExpression(b, dependencies);
			case Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), BitAnd(a, b, _), BitXor(a, b, _), BitOr(a, b, _), ShiftLeft(a, b, _),
				ShiftRight(a, b, _), UnsignedShiftRight(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _), GreaterEqual(a, b, _), Equal(a, b, _),
				NotEqual(a, b, _):
				scanExpression(a, dependencies);
				scanExpression(b, dependencies);
			case Not(value, _):
				scanExpression(value, dependencies);
			case Negate(value, _):
				scanExpression(value, dependencies);
			case And(left, right, _), Or(left, right, _):
				scanExpression(left, dependencies);
				scanExpression(right, dependencies);
			case Conditional(predicate, whenTrue, whenFalse, _):
				scanExpression(predicate, dependencies);
				scanExpression(whenTrue, dependencies);
				scanExpression(whenFalse, dependencies);
			case BlockExpression(statements, value, _):
				for (statement in statements)
					scanStatement(statement, dependencies);
				scanExpression(value, dependencies);
			case ThrowExpression(value, _):
				scanExpression(value, dependencies);
			case Cast(value, target, _):
				scanExpression(value, dependencies);
				if (target != null)
					scanType(target, dependencies);
			case SwitchExpression(subject, cases, fallback, _):
				scanExpression(subject, dependencies);
				for (switchCase in cases) {
					scanExpression(switchCase.value, dependencies);
					var guard = switchCase.guard;
					if (guard != null)
						scanExpression(guard, dependencies);
					scanExpression(switchCase.result, dependencies);
				}
				var fallbackExpression = fallback;
				if (fallbackExpression != null)
					scanExpression(fallbackExpression, dependencies);
			case ObjectLiteral(fields, _):
				for (field in fields)
					scanExpression(field.value, dependencies);
			case ArrayLiteral(values, _):
				for (value in values)
					scanExpression(value, dependencies);
			case MapLiteral(entries, _):
				for (mapEntry in entries) {
					scanExpression(mapEntry.key, dependencies);
					scanExpression(mapEntry.value, dependencies);
				}
			case ArrayComprehension(_, _, iterable, predicate, value, _):
				scanExpression(iterable, dependencies);
				if (predicate != null)
					scanExpression(predicate, dependencies);
				scanExpression(value, dependencies);
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				scanExpression(iterable, dependencies);
				if (predicate != null)
					scanExpression(predicate, dependencies);
				scanExpression(key, dependencies);
				scanExpression(value, dependencies);
			case Range(start, rangeEnd, _):
				scanExpression(start, dependencies);
				scanExpression(rangeEnd, dependencies);
			case Index(array, offset, _):
				scanExpression(array, dependencies);
				scanExpression(offset, dependencies);
			case PostfixIncrement(target, _, _):
				scanExpression(target, dependencies);
			case Member(object, _, _):
				scanExpression(object, dependencies);
			case Variable(name, _):
				scanQualifiedDependency(name, dependencies);
			case MethodCall(object, _, args, _):
				scanExpression(object, dependencies);
				for (a in args)
					scanExpression(a, dependencies);
			case Call(name, args, _):
				addQualifiedOwner(name, dependencies);
				for (a in args)
					scanExpression(a, dependencies);
			case ClosureCall(callee, args, _):
				scanExpression(callee, dependencies);
				for (a in args)
					scanExpression(a, dependencies);
			case New(typeName, args, _):
				dependencies.set(typeName, true);
				for (a in args)
					scanExpression(a, dependencies);
			case NewGeneric(typeName, typeArguments, args, _):
				dependencies.set(typeName, true);
				for (type in typeArguments)
					scanType(type, dependencies);
				for (a in args)
					scanExpression(a, dependencies);
			case NewArray(element, length, _):
				scanType(element, dependencies);
				scanExpression(length, dependencies);
			case NativeLayoutQuery(_, type, _, _):
				scanType(type, dependencies);
			case NewMap(key, value, _):
				scanType(key, dependencies);
				scanType(value, dependencies);
			case Lambda(arguments, statements, _):
				for (argument in arguments) {
					scanType(argument.type, dependencies);
					if (argument.defaultValue != null)
						scanExpression(argument.defaultValue, dependencies);
				}
				for (statement in statements)
					scanStatement(statement, dependencies);
			default:
		}

	static function scanQualifiedDependency(name:String, dependencies:Map<String, Bool>):Void {
		addQualifiedOwner(name, dependencies);
	}

	static function scanType(type:AstType, dependencies:Map<String, Bool>):Void {
		// AstChildren owns exhaustive type recursion. This callback classifies
		// every type node, including declaration-bearing generic arguments.
		AstChildren.walkType(type, function(child:AstType):Void {
			switch child {
				case NamedType(name), AppliedType(name, _), NativeAbstractType(name, _):
					dependencies.set(name, true);
				case IntType, BoolType, FloatType, StringType, VoidType, InferredType, ErrorType(_),
					ArrayType(_), MapType(_, _), NullableType(_), FunctionType(_, _), AnonymousType(_):
				}
		});
	}

	static function addQualifiedOwner(name:String, dependencies:Map<String, Bool>):Void {
		var length = name.length, segmentStart = 0, hasSeparator = false;
		for (cursor in 0...length)
			if (name.charCodeAt(cursor) == 46) {
				hasSeparator = true;
				break;
			}
		if (!hasSeparator)
			return;
		for (cursor in 0...length + 1)
			if (cursor == length || name.charCodeAt(cursor) == 46) {
				if (cursor > segmentStart) {
					var first = name.charCodeAt(segmentStart);
					if (first >= 65 && first <= 90) {
						dependencies.set(name.substring(0, cursor), true);
						return;
					}
				}
				segmentStart = cursor + 1;
			}
	}
}
