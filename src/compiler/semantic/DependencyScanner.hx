package compiler.semantic;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

/** Collects qualified source dependencies referenced by syntax trees. */
class DependencyScanner {
	/**
	 * Marks a name that is only a dependency when a source module of that name exists: a type written in a local
	 * annotation, a cast, or a catch clause may as well be a built-in (`Dynamic`), a type parameter, or a type that is
	 * resolved elsewhere, so the module analyzer keeps such a name only when it names a module.
	 */
	public static inline final OPTIONAL_PREFIX = "?";

	public static function scanStatement(s:AstStatement, dependencies:Map<String, Bool>):Void
		switch s {
			case ErrorStatement(_):
			case UninitializedDeclaration(_, type, _):
				scanAnnotation(type, dependencies);
			case VarDeclaration(_, type, e, _):
				// A type written only in the annotation still has to be loaded.
				if (type != null)
					scanAnnotation(type, dependencies);
				scanExpression(e, dependencies);
			case Assignment(_, e, _), Return(e, _), Throw(e, _):
				scanExpression(e, dependencies);
			case Try(tryBranch, catches, _):
				for (x in tryBranch)
					scanStatement(x, dependencies);
				for (catchClause in catches) {
					scanAnnotation(catchClause.type, dependencies);
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
			case Cast(value, type, _):
				if (type != null)
					scanAnnotation(type, dependencies);
				scanExpression(value, dependencies);
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
			case ArrayComprehension(_, _, iterable, predicate, value, _, _):
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
			case MethodCall(object, name, args, _):
				scanArrayLibraryMethod(name, dependencies);
				scanExpression(object, dependencies);
				for (a in args)
					scanExpression(a, dependencies);
			case Call(name, args, _):
				if (name.indexOf(".") >= 0)
					scanArrayLibraryMethod(compiler.QualifiedName.last(name), dependencies);
				addQualifiedOwner(name, dependencies);
				for (a in args)
					scanExpression(a, dependencies);
			case ClosureCall(callee, args, _):
				scanExpression(callee, dependencies);
				for (a in args)
					scanExpression(a, dependencies);
			case New(typeName, args, _), NewGeneric(typeName, _, args, _):
				dependencies.set(typeName, true);
				for (a in args)
					scanExpression(a, dependencies);
			case NewArray(_, length, _):
				scanExpression(length, dependencies);
			case NativeLayoutQuery(_, type, _, _):
				scanType(type, dependencies);
			case NewMap(_, _, _):
			case Lambda(arguments, statements, _):
				// Local functions and anonymous functions are lambdas; modules
				// referenced only inside their bodies are dependencies too.
				for (argument in arguments)
					if (argument.type != null)
						scanType(argument.type, dependencies);
				for (statement in statements)
					scanStatement(statement, dependencies);
			default:
		}

	/** A call that may be an array method implemented in the stdlib needs that module loaded. */
	static function scanArrayLibraryMethod(methodName:String, dependencies:Map<String, Bool>):Void
		if (compiler.runtime.ArrayLibrary.provides(methodName))
			dependencies.set(compiler.runtime.ArrayLibrary.CLASS_NAME, true);

	static function scanQualifiedDependency(name:String, dependencies:Map<String, Bool>):Void {
		addQualifiedOwner(name, dependencies);
	}

	/** Like `scanType`, for names that count as dependencies only when they name a source module. */
	static function scanAnnotation(type:AstType, dependencies:Map<String, Bool>):Void {
		var names:Map<String, Bool> = [];
		scanType(type, names);
		for (name in names.keys())
			dependencies.set(OPTIONAL_PREFIX + name, true);
	}

	static function scanType(type:AstType, dependencies:Map<String, Bool>):Void
		switch type {
			case NamedType(name) | AppliedType(name, _):
				dependencies.set(name, true);
			case ArrayType(element) | NullableType(element):
				scanType(element, dependencies);
			case MapType(key, value):
				scanType(key, dependencies);
				scanType(value, dependencies);
			case FunctionType(arguments, result):
				for (argument in arguments)
					scanType(argument, dependencies);
				scanType(result, dependencies);
			case AnonymousType(fields):
				for (field in fields)
					scanType(field.type, dependencies);
			case _:
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
