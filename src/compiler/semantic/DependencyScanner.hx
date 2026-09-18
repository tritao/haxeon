package compiler.semantic;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.AstChildren;

/** Collects qualified source dependencies referenced by syntax trees. */
class DependencyScanner {
	public static function scanStatement(s:AstStatement, dependencies:Map<String, Bool>, ?typeParameters:Array<String>):Void
		switch s {
			case ErrorStatement(_):
			case UninitializedDeclaration(_, type, _):
				scanType(type, dependencies, typeParameters);
			case VarDeclaration(_, type, e, _):
				if (type != null)
					scanType(type, dependencies, typeParameters);
				scanExpression(e, dependencies, typeParameters);
			case Assignment(_, e, _), Return(e, _), Throw(e, _):
				scanExpression(e, dependencies, typeParameters);
			case Try(tryBranch, catches, _):
				for (x in tryBranch)
					scanStatement(x, dependencies, typeParameters);
				for (catchClause in catches) {
					scanType(catchClause.type, dependencies, typeParameters);
					for (x in catchClause.statements)
						scanStatement(x, dependencies, typeParameters);
				}
			case IndexAssignment(array, offset, e, _):
				scanExpression(array, dependencies, typeParameters);
				scanExpression(offset, dependencies, typeParameters);
				scanExpression(e, dependencies, typeParameters);
			case FieldAssignment(object, _, e, _):
				scanExpression(object, dependencies, typeParameters);
				scanExpression(e, dependencies, typeParameters);
			case ReturnVoid(_):
			case Break(_), Continue(_):
			case Increment(_, _, _):
			case If(c, y, n, _):
				scanExpression(c, dependencies, typeParameters);
				for (x in y)
					scanStatement(x, dependencies, typeParameters);
				for (x in n)
					scanStatement(x, dependencies, typeParameters);
			case While(c, b, _):
				scanExpression(c, dependencies, typeParameters);
				for (x in b)
					scanStatement(x, dependencies, typeParameters);
			case DoWhile(b, c, _):
				for (x in b)
					scanStatement(x, dependencies, typeParameters);
				scanExpression(c, dependencies, typeParameters);
			case ForIn(_, _, iterable, b, _):
				scanExpression(iterable, dependencies, typeParameters);
				for (x in b)
					scanStatement(x, dependencies, typeParameters);
			case Switch(expression, cases, defaultBranch, _, _):
				scanExpression(expression, dependencies, typeParameters);
				for (switchCase in cases) {
					scanExpression(switchCase.value, dependencies, typeParameters);
					var guard = switchCase.guard;
					if (guard != null)
						scanExpression(guard, dependencies, typeParameters);
					for (x in switchCase.statements)
						scanStatement(x, dependencies, typeParameters);
				}
				for (x in defaultBranch)
					scanStatement(x, dependencies, typeParameters);
			case Expression(e, _):
				scanExpression(e, dependencies, typeParameters);
		}

	public static function scanExpression(e:AstExpression, dependencies:Map<String, Bool>, ?typeParameters:Array<String>):Void
		switch e {
			case Add(a, b, _):
				scanExpression(a, dependencies, typeParameters);
				scanExpression(b, dependencies, typeParameters);
			case Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), BitAnd(a, b, _), BitXor(a, b, _), BitOr(a, b, _), ShiftLeft(a, b, _),
				ShiftRight(a, b, _), UnsignedShiftRight(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _), GreaterEqual(a, b, _), Equal(a, b, _),
				NotEqual(a, b, _):
				scanExpression(a, dependencies, typeParameters);
				scanExpression(b, dependencies, typeParameters);
			case Not(value, _):
				scanExpression(value, dependencies, typeParameters);
			case Negate(value, _):
				scanExpression(value, dependencies, typeParameters);
			case And(left, right, _), Or(left, right, _):
				scanExpression(left, dependencies, typeParameters);
				scanExpression(right, dependencies, typeParameters);
			case Conditional(predicate, whenTrue, whenFalse, _):
				scanExpression(predicate, dependencies, typeParameters);
				scanExpression(whenTrue, dependencies, typeParameters);
				scanExpression(whenFalse, dependencies, typeParameters);
			case BlockExpression(statements, value, _):
				for (statement in statements)
					scanStatement(statement, dependencies, typeParameters);
				scanExpression(value, dependencies, typeParameters);
			case ThrowExpression(value, _):
				scanExpression(value, dependencies, typeParameters);
			case Cast(value, target, _):
				scanExpression(value, dependencies, typeParameters);
				if (target != null)
					scanType(target, dependencies, typeParameters);
			case SwitchExpression(subject, cases, fallback, _):
				scanExpression(subject, dependencies, typeParameters);
				for (switchCase in cases) {
					scanExpression(switchCase.value, dependencies, typeParameters);
					var guard = switchCase.guard;
					if (guard != null)
						scanExpression(guard, dependencies, typeParameters);
					scanExpression(switchCase.result, dependencies, typeParameters);
				}
				var fallbackExpression = fallback;
				if (fallbackExpression != null)
					scanExpression(fallbackExpression, dependencies, typeParameters);
			case ObjectLiteral(fields, _):
				for (field in fields)
					scanExpression(field.value, dependencies, typeParameters);
			case ArrayLiteral(values, _):
				for (value in values)
					scanExpression(value, dependencies, typeParameters);
			case MapLiteral(entries, _):
				for (mapEntry in entries) {
					scanExpression(mapEntry.key, dependencies, typeParameters);
					scanExpression(mapEntry.value, dependencies, typeParameters);
				}
			case ArrayComprehension(_, _, iterable, predicate, value, _):
				scanExpression(iterable, dependencies, typeParameters);
				if (predicate != null)
					scanExpression(predicate, dependencies, typeParameters);
				scanExpression(value, dependencies, typeParameters);
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				scanExpression(iterable, dependencies, typeParameters);
				if (predicate != null)
					scanExpression(predicate, dependencies, typeParameters);
				scanExpression(key, dependencies, typeParameters);
				scanExpression(value, dependencies, typeParameters);
			case Range(start, rangeEnd, _):
				scanExpression(start, dependencies, typeParameters);
				scanExpression(rangeEnd, dependencies, typeParameters);
			case Index(array, offset, _):
				scanExpression(array, dependencies, typeParameters);
				scanExpression(offset, dependencies, typeParameters);
			case PostfixIncrement(target, _, _):
				scanExpression(target, dependencies, typeParameters);
			case Member(object, _, _):
				scanExpression(object, dependencies, typeParameters);
			case Variable(name, _):
				scanQualifiedDependency(name, dependencies);
			case MethodCall(object, _, args, _):
				scanExpression(object, dependencies, typeParameters);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case Call(name, args, _):
				addQualifiedOwner(name, dependencies);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case ClosureCall(callee, args, _):
				scanExpression(callee, dependencies, typeParameters);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case New(typeName, args, _):
				if (typeParameters == null || typeParameters.indexOf(typeName) < 0)
					dependencies.set(typeName, true);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case NewGeneric(typeName, typeArguments, args, _):
				if (typeParameters == null || typeParameters.indexOf(typeName) < 0)
					dependencies.set(typeName, true);
				for (type in typeArguments)
					scanType(type, dependencies, typeParameters);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case NewArray(element, length, _):
				scanType(element, dependencies, typeParameters);
				scanExpression(length, dependencies, typeParameters);
			case NativeLayoutQuery(_, type, _, _):
				scanType(type, dependencies, typeParameters);
			case NewMap(key, value, _):
				scanType(key, dependencies, typeParameters);
				scanType(value, dependencies, typeParameters);
			case Lambda(arguments, statements, _):
				for (argument in arguments) {
					scanType(argument.type, dependencies, typeParameters);
					if (argument.defaultValue != null)
						scanExpression(argument.defaultValue, dependencies, typeParameters);
				}
				for (statement in statements)
					scanStatement(statement, dependencies, typeParameters);
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_), EmptyExpression(_), ErrorExpression(_):
		}

	static function scanQualifiedDependency(name:String, dependencies:Map<String, Bool>):Void {
		addQualifiedOwner(name, dependencies);
	}

	static function scanType(type:AstType, dependencies:Map<String, Bool>, ?typeParameters:Array<String>):Void {
		// AstChildren owns exhaustive type recursion. This callback classifies
		// every type node, including declaration-bearing generic arguments.
		AstChildren.walkType(type, function(child:AstType):Void {
			switch child {
				case NamedType(name), AppliedType(name, _), NativeAbstractType(name, _):
					if (typeParameters == null || typeParameters.indexOf(name) < 0)
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
