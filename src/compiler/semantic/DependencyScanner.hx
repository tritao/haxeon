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

	public static function scanStatement(s:AstStatement, dependencies:Map<String, Bool>, ?typeParameters:Array<String>):Void
		switch s {
			case ErrorStatement(_):
			case UninitializedDeclaration(_, type, _):
				scanAnnotation(type, dependencies, typeParameters);
			case VarDeclaration(_, type, e, _):
				// A type written only in the annotation still has to be loaded.
				if (type != null)
					scanAnnotation(type, dependencies, typeParameters);
				scanExpression(e, dependencies, typeParameters);
			case Assignment(_, e, _), Return(e, _), Throw(e, _):
				scanExpression(e, dependencies, typeParameters);
			case Try(tryBranch, catches, _):
				for (x in tryBranch)
					scanStatement(x, dependencies, typeParameters);
				for (catchClause in catches) {
					scanAnnotation(catchClause.type, dependencies, typeParameters);
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
			case Cast(value, type, _):
				if (type != null)
					scanAnnotation(type, dependencies, typeParameters);
				scanExpression(value, dependencies, typeParameters);
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
			case ArrayComprehension(_, _, iterable, predicate, value, _, _):
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
			case MethodCall(object, name, args, _):
				scanArrayLibraryMethod(name, dependencies);
				scanExpression(object, dependencies, typeParameters);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case Call(name, args, _):
				if (name.indexOf(".") >= 0)
					scanArrayLibraryMethod(compiler.QualifiedName.last(name), dependencies);
				addQualifiedOwner(name, dependencies);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case ClosureCall(callee, args, _):
				scanExpression(callee, dependencies, typeParameters);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case New(typeName, args, _), NewGeneric(typeName, _, args, _):
				dependencies.set(typeName, true);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case NewArray(_, length, _):
				scanExpression(length, dependencies, typeParameters);
			case NativeLayoutQuery(_, type, _, _):
				scanType(type, dependencies, typeParameters);
			case NewMap(_, _, _):
			case Lambda(arguments, statements, _):
				// Local functions and anonymous functions are lambdas; modules
				// referenced only inside their bodies are dependencies too.
				for (argument in arguments)
					if (argument.type != null)
						scanType(argument.type, dependencies, typeParameters);
				for (statement in statements)
					scanStatement(statement, dependencies, typeParameters);
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
	static function scanAnnotation(type:AstType, dependencies:Map<String, Bool>, ?typeParameters:Array<String>):Void {
		var names:Map<String, Bool> = [];
		scanType(type, names, typeParameters);
		for (name in names.keys())
			dependencies.set(OPTIONAL_PREFIX + name, true);
	}

	static function scanType(type:AstType, dependencies:Map<String, Bool>, ?typeParameters:Array<String>):Void
		switch type {
			case NamedType(name):
				if (typeParameters == null || typeParameters.indexOf(name) < 0)
					dependencies.set(name, true);
			case AppliedType(name, arguments):
				if (typeParameters == null || typeParameters.indexOf(name) < 0)
					dependencies.set(name, true);
				for (argument in arguments)
					scanType(argument, dependencies, typeParameters);
			case ArrayType(element) | NullableType(element):
				scanType(element, dependencies, typeParameters);
			case MapType(key, value):
				scanType(key, dependencies, typeParameters);
				scanType(value, dependencies, typeParameters);
			case FunctionType(arguments, result):
				for (argument in arguments)
					scanType(argument, dependencies, typeParameters);
				scanType(result, dependencies, typeParameters);
			case AnonymousType(fields):
				for (field in fields)
					scanType(field.type, dependencies, typeParameters);
			case _:
		}

	/**
		Records the types a cast names as optional dependencies (`false`): their modules load when
		they exist, but a name that is no module (`Dynamic`, a type parameter) is not missing.
	**/
	static function scanOptionalType(type:AstType, dependencies:Map<String, Bool>):Void {
		var names:Map<String, Bool> = [];
		scanType(type, names);
		for (name in names.keys())
			if (!dependencies.exists(name))
				dependencies.set(name, false);
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
