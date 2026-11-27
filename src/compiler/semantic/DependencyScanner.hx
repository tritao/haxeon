package compiler.semantic;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

/** Collects qualified source dependencies referenced by syntax trees. */
class DependencyScanner {
	public static function scanStatement(s:AstStatement, dependencies:ScannedDependencies,
			?typeParameters:Array<String>):Void
		switch s {
			case AnnotatedStatement(_, inner, _):
				scanStatement(inner, dependencies, typeParameters);
			case ErrorStatement(_):
			case UninitializedDeclaration(_, type, _):
				scanAnnotation(type, dependencies, typeParameters);
			case ScopedDeclaration(_, type, e, _):
				dependencies.required.set("Disposable", true);
				if (type != null)
					scanAnnotation(type, dependencies, typeParameters);
				scanExpression(e, dependencies, typeParameters);
			case VarDeclaration(_, type, e, _), TemporaryDeclaration(_, type, e, _):
				// A type written only in the annotation still has to be loaded.
				if (type != null) {
					var parameters = switch e {
						case Lambda(_, _, _, _, _, _, generic) if (generic != null):
							typeParameters == null ? generic.parameters : typeParameters.concat(generic.parameters);
						default: typeParameters;
					};
					scanAnnotation(type, dependencies, parameters);
				}
				scanExpression(e, dependencies, typeParameters);
			case Assignment(_, e, _), TemporaryAssignment(_, e, _), DeclaredAssignment(_, _, e, _), Return(e, _),
				Throw(e, _):
				scanExpression(e, dependencies, typeParameters);
			case Defer(body, _):
				for (statement in body)
					scanStatement(statement, dependencies, typeParameters);
			case Try(tryBranch, catches, _):
				for (x in tryBranch)
					scanStatement(x, dependencies, typeParameters);
				for (catchClause in catches) {
					scanAnnotation(catchClause.type, dependencies, typeParameters);
					// A typed catch tests what haxe.Exception's catch helpers make of the thrown value (TypedCatchSubject),
					// when the standard library has them.
					if (!catchClause.type.match(NamedType("Dynamic")))
						dependencies.optional.set(compiler.runtime.RuntimeType.EXCEPTION, true);
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
			case Switch(expression, cases, defaultBranch, hasDefault, _):
				// A switch without a default may cover a closed set, whose implicit default throws an UnmatchedValue.
				if (!hasDefault)
					dependencies.optional.set(compiler.runtime.RuntimeType.UNMATCHED_VALUE, true);
				scanExpression(expression, dependencies, typeParameters);
				for (switchCase in cases) {
					for (pattern in switchCase.patterns)
						scanExpression(pattern, dependencies, typeParameters);
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

	public static function scanExpression(e:AstExpression, dependencies:ScannedDependencies,
			?typeParameters:Array<String>):Void
		switch e {
			case AnnotatedExpression(_, inner, _):
				scanExpression(inner, dependencies, typeParameters);
			case Add(a, b, _):
				scanExpression(a, dependencies, typeParameters);
				scanExpression(b, dependencies, typeParameters);
			case Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), BitAnd(a, b, _), BitXor(a, b, _),
				BitOr(a, b, _), ShiftLeft(a, b, _),
				ShiftRight(a, b, _), UnsignedShiftRight(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _),
				GreaterEqual(a, b, _), Equal(a, b, _),
				NotEqual(a, b, _):
				scanExpression(a, dependencies, typeParameters);
				scanExpression(b, dependencies, typeParameters);
			case Not(value, _), Propagate(value, _):
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
			case AssignmentValue(store, _):
				scanStatement(store, dependencies, typeParameters);
			case ThrowExpression(value, _), Capture(_, value, _), Spread(value, _), NamedArgument(_, value, _):
				scanExpression(value, dependencies, typeParameters);
			case Extractor(expression, pattern, _):
				scanExpression(expression, dependencies, typeParameters);
				scanExpression(pattern, dependencies, typeParameters);
			case Cast(value, type, _):
				if (type != null)
					scanAnnotation(type, dependencies, typeParameters);
				scanExpression(value, dependencies, typeParameters);
			case CheckType(value, type, _):
				scanAnnotation(type, dependencies, typeParameters);
				scanExpression(value, dependencies, typeParameters);
			case GenericCall(written, typeArguments, _):
				for (type in typeArguments)
					scanAnnotation(type, dependencies, typeParameters);
				scanExpression(written, dependencies, typeParameters);
			case SwitchExpression(subject, cases, fallback, _):
				if (fallback == null)
					dependencies.optional.set(compiler.runtime.RuntimeType.UNMATCHED_VALUE, true);
				scanExpression(subject, dependencies, typeParameters);
				for (switchCase in cases) {
					for (pattern in switchCase.patterns)
						scanExpression(pattern, dependencies, typeParameters);
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
				dependencies.companionOwners.set("Map", true);
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
				dependencies.companionOwners.set("Map", true);
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
				scanLibraryMethod(name, dependencies);
				scanExpression(object, dependencies, typeParameters);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case Call(name, args, _):
				if (compiler.runtime.ArrayLibrary.providesLastOf(name))
					dependencies.required.set(compiler.runtime.ArrayLibrary.CLASS_NAME, true);
				if (compiler.runtime.MapLibrary.providesLastOf(name))
					dependencies.required.set(compiler.runtime.MapLibrary.CLASS_NAME, true);
				// The stdlib may implement it in Haxe (`RuntimeType.STRING_FROM_CHAR_CODE`).
				if (name == "String.fromCharCode")
					dependencies.optional.set(compiler.runtime.RuntimeType.STRING_CODES, true);
				addQualifiedOwner(name, dependencies);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case ClosureCall(callee, args, _):
				scanExpression(callee, dependencies, typeParameters);
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case New(typeName, args, _), NewGeneric(typeName, _, args, _):
				dependencies.required.set(typeName, true);
				switch e {
					case NewGeneric(_, typeArguments, _, _):
						for (type in typeArguments)
							scanAnnotation(type, dependencies, typeParameters);
					default:
				}
				for (a in args)
					scanExpression(a, dependencies, typeParameters);
			case NewArray(element, length, _):
				scanAnnotation(element, dependencies, typeParameters);
				scanExpression(length, dependencies, typeParameters);
			case NativeLayoutQuery(_, type, _, _):
				scanType(type, dependencies.required, dependencies.companionOwners, typeParameters);
			case KeyPathLiteral(root, _, _):
				// The parser cannot yet distinguish a qualified root from its field suffix.
				// Load existing source prefixes; the typer diagnoses an unresolved root.
				switch root {
					case NamedType(name):
						var candidate = name;
						while (candidate.length > 0) {
							dependencies.optional.set(candidate, true);
							candidate = compiler.core.QualifiedName.parentOrEmpty(candidate);
						}
					default: scanType(root, dependencies.required, dependencies.companionOwners, typeParameters);
				}
			case NewMap(key, value, _):
				if (mayUseObjectMap(key, null))
					dependencies.companionOwners.set("Map", true);
				scanAnnotation(key, dependencies, typeParameters);
				scanAnnotation(value, dependencies, typeParameters);
			case Lambda(arguments, statements, _, _, _, _, generic):
				if (generic != null) {
					typeParameters = typeParameters == null
						? generic.parameters : typeParameters.concat(generic.parameters);
					for (constraint in generic.constraints)
						scanAnnotation(constraint.type, dependencies, typeParameters);
				}
				// Local functions and anonymous functions are lambdas; modules
				// referenced only inside their bodies are dependencies too.
				for (argument in arguments)
					if (argument.type != null)
						scanType(argument.type, dependencies.required, dependencies.companionOwners, typeParameters);
				for (statement in statements)
					scanStatement(statement, dependencies, typeParameters);
			default:
		}

	/** A call that may be an array or map method implemented in the stdlib needs that module loaded. */
	static function scanLibraryMethod(methodName:String, dependencies:ScannedDependencies):Void {
		if (compiler.runtime.ArrayLibrary.provides(methodName))
			dependencies.required.set(compiler.runtime.ArrayLibrary.CLASS_NAME, true);
		if (compiler.runtime.MapLibrary.provides(methodName))
			dependencies.required.set(compiler.runtime.MapLibrary.CLASS_NAME, true);
	}

	static function scanQualifiedDependency(name:String, dependencies:ScannedDependencies):Void {
		addQualifiedOwner(name, dependencies);
	}

	/** Like `scanType`, for names that count as dependencies only when they name a source module. */
	static function scanAnnotation(type:AstType, dependencies:ScannedDependencies, ?typeParameters:Array<String>):Void {
		scanType(type, dependencies.optional, dependencies.companionOwners, typeParameters);
	}

	static function scanType(type:AstType, names:Map<String, Bool>, companionOwners:Map<String, Bool>,
			?typeParameters:Array<String>):Void
		switch type {
			case NamedType(name):
				if (typeParameters == null || typeParameters.indexOf(name) < 0)
					names.set(name, true);
			case AppliedType(name, arguments):
				if (name == "KeyValueIterable")
					companionOwners.set(name, true);
				if (name != "KeyPath" && name != "WritableKeyPath"
					&& (typeParameters == null || typeParameters.indexOf(name) < 0))
					names.set(name, true);
				for (argument in arguments)
					scanType(argument, names, companionOwners, typeParameters);
			case ArrayType(element) | NullableType(element):
				scanType(element, names, companionOwners, typeParameters);
			case MapType(key, value):
				if (mayUseObjectMap(key, typeParameters))
					companionOwners.set("Map", true);
				scanType(key, names, companionOwners, typeParameters);
				scanType(value, names, companionOwners, typeParameters);
			case FunctionType(arguments, result, _):
				for (argument in arguments)
					scanType(argument, names, companionOwners, typeParameters);
				scanType(result, names, companionOwners, typeParameters);
			case AnonymousType(fields):
				for (field in fields) {
					if (field.name == "keyValueIterator")
						companionOwners.set("KeyValueIterable", true);
					scanType(field.type, names, companionOwners, typeParameters);
				}
			case _:
		}

	/** Only a nominal reference key can select ObjectMap. Generic constructors scan without excluding their parameters. */
	public static function mayUseObjectMap(key:AstType, ?parameters:Array<String>):Bool
		return switch key {
			case NamedType(name), AppliedType(name, _):
				name != "Int" && name != "String" && (parameters == null || parameters.indexOf(name) < 0);
			default: false;
		};

	static function addQualifiedOwner(name:String, dependencies:ScannedDependencies):Void {
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
						dependencies.required.set(name.substring(0, cursor), true);
						return;
					}
				}
				segmentStart = cursor + 1;
			}
	}
}
