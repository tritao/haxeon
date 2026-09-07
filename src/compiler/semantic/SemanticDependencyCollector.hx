package compiler.semantic;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.modules.ModuleState;
import compiler.types.FieldInference;
import compiler.modules.ModuleState.SemanticDependency;
import compiler.modules.ModuleState.SemanticDependencyKind;

/** Records semantic dependency edges without owning module/session invalidation. */
class SemanticDependencyCollector {
	public static function collectSemanticDependencies(state:ModuleState, entry:String,
			typeAliases:Map<String, String>):Map<String, Array<SemanticDependency>> {
		var result:Map<String, Array<SemanticDependency>> = [],
			ast = state.parsedAst();
		for (fn in ast.functions) {
			var owner = state.name == entry && fn.name == "main" ? "main" : state.name + "." + fn.name;
			for (argument in fn.arguments)
				addTypeDependency(result, owner, SemanticDependencyKind.Signature, argument.type, typeAliases);
			addTypeDependency(result, owner, SemanticDependencyKind.Signature, fn.result, typeAliases);
			addBodyDependencies(result, owner, fn.statements, state.name, entry);
		}
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
				base = classDecl.base;
			if (base != null)
				addTypeDependency(result, className, SemanticDependencyKind.Layout, base, typeAliases);
			for (interfaceType in classDecl.interfaces)
				addTypeDependency(result, className, SemanticDependencyKind.Layout, interfaceType, typeAliases);
			for (field in classDecl.fields) {
				addTypeDependency(result, className, SemanticDependencyKind.Layout, FieldInference.parsedType(field), typeAliases);
				var initializer = field.initializer;
				if (initializer != null)
					addExpressionDependencies(result, className + "." + field.name, SemanticDependencyKind.Initializer, initializer, state.name, entry);
			}
			for (method in classDecl.methods) {
				var owner = className + "." + method.name;
				for (argument in method.arguments)
					addTypeDependency(result, owner, SemanticDependencyKind.Signature, argument.type, typeAliases);
				addTypeDependency(result, owner, SemanticDependencyKind.Signature, method.result, typeAliases);
				addBodyDependencies(result, owner, method.statements, state.name, entry);
			}
		}
		return result;
	}

	public static function addTypeDependency(result:Map<String, Array<SemanticDependency>>, owner:String, kind:SemanticDependencyKind,
			type:compiler.syntax.Ast.AstType, aliases:Map<String, String>):Void
		switch type {
			case NativeAbstractType(declaration, _):
				addDependency(result, owner, kind, ModuleCanonicalizer.resolveTypeName(declaration, aliases));
			case NamedType(name):
				addDependency(result, owner, kind, ModuleCanonicalizer.resolveTypeName(name, aliases));
			case AppliedType(name, arguments):
				addDependency(result, owner, kind, ModuleCanonicalizer.resolveTypeName(name, aliases));
				for (argument in arguments)
					addTypeDependency(result, owner, kind, argument, aliases);
			case ArrayType(element), NullableType(element):
				addTypeDependency(result, owner, kind, element, aliases);
			case MapType(key, value):
				addTypeDependency(result, owner, kind, key, aliases);
				addTypeDependency(result, owner, kind, value, aliases);
			case FunctionType(arguments, returnType):
				for (argument in arguments)
					addTypeDependency(result, owner, kind, argument, aliases);
				addTypeDependency(result, owner, kind, returnType, aliases);
			case AnonymousType(fields):
				for (field in fields)
					addTypeDependency(result, owner, kind, field.type, aliases);
			case IntType, BoolType, FloatType, StringType, VoidType, InferredType, ErrorType(_):
		}

	public static function addBodyDependencies(result:Map<String, Array<SemanticDependency>>, owner:String, statements:Array<AstStatement>, module:String,
			entry:String):Void
		for (statement in statements)
			switch statement {
				case ErrorStatement(_):
				case UninitializedDeclaration(_, type, _):
					addTypeDependency(result, owner, SemanticDependencyKind.Body, type, []);
				case VarDeclaration(_, type, expression, _):
					addOptionalTypeDependency(result, owner, SemanticDependencyKind.Body, type, []);
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, expression, module, entry);
				case Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, expression, module, entry);
				case IndexAssignment(array, offset, expression, _):
					for (item in [array, offset, expression])
						addExpressionDependencies(result, owner, SemanticDependencyKind.Body, item, module, entry);
				case FieldAssignment(object, _, expression, _):
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, object, module, entry);
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, expression, module, entry);
				case If(predicate, yes, no, _):
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, predicate, module, entry);
					addBodyDependencies(result, owner, yes, module, entry);
					addBodyDependencies(result, owner, no, module, entry);
				case While(predicate, body, _):
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, predicate, module, entry);
					addBodyDependencies(result, owner, body, module, entry);
				case DoWhile(body, predicate, _):
					addBodyDependencies(result, owner, body, module, entry);
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, predicate, module, entry);
				case ForIn(_, _, iterable, body, _):
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, iterable, module, entry);
					addBodyDependencies(result, owner, body, module, entry);
				case Try(body, catches, _):
					addBodyDependencies(result, owner, body, module, entry);
					for (clause in catches)
						addBodyDependencies(result, owner, clause.statements, module, entry);
				case Switch(expression, cases, fallback, _, _):
					addExpressionDependencies(result, owner, SemanticDependencyKind.Body, expression, module, entry);
					for (switchCase in cases) {
						addExpressionDependencies(result, owner, SemanticDependencyKind.Body, switchCase.value, module, entry);
						addOptionalExpressionDependencies(result, owner, SemanticDependencyKind.Body, switchCase.guard, module, entry);
						addBodyDependencies(result, owner, switchCase.statements, module, entry);
					}
					addBodyDependencies(result, owner, fallback, module, entry);
				case ReturnVoid(_), Break(_), Continue(_), Increment(_, _, _):
			}

	public static function addOptionalTypeDependency(result:Map<String, Array<SemanticDependency>>, owner:String, kind:SemanticDependencyKind,
			type:Null<compiler.syntax.Ast.AstType>, aliases:Map<String, String>):Void {
		if (type != null)
			addTypeDependency(result, owner, kind, type, aliases);
	}

	public static function addOptionalExpressionDependencies(result:Map<String, Array<SemanticDependency>>, owner:String, kind:SemanticDependencyKind,
			expression:Null<AstExpression>, module:String, entry:String):Void {
		if (expression != null)
			addExpressionDependencies(result, owner, kind, expression, module, entry);
	}

	public static function addExpressionDependencies(result:Map<String, Array<SemanticDependency>>, owner:String, kind:SemanticDependencyKind,
			expression:AstExpression, module:String, entry:String):Void {
		var calls:Map<String, Bool> = [], locals:Map<String, String> = [];
		scanCallExpression(expression, calls, locals);
		for (name in calls.keys())
			addDependency(result, owner, kind, ModuleCanonicalizer.canonicalName(module, entry, name));
	}

	public static function addDependency(result:Map<String, Array<SemanticDependency>>, owner:String, kind:SemanticDependencyKind, target:String,
			?targetId:String):Void {
		var dependencies:Array<SemanticDependency>;
		if (result.exists(owner))
			dependencies = result.get(owner);
		else {
			dependencies = [];
			result.set(owner, dependencies);
		}
		for (dependency in dependencies)
			if (dependency.kind == kind && dependency.target == target && dependency.targetId == targetId)
				return;
		dependencies.push({kind: kind, target: target, targetId: targetId});
	}

	public static function sameDependencyTarget(dependency:String, changed:String):Bool
		return dependency == changed || StringTools.endsWith(dependency, "." + changed) || StringTools.endsWith(changed, "." + dependency);

	public static function scanCalls(statement:AstStatement, calls:Map<String, Bool>, aliases:Map<String, String>):Void
		switch statement {
			case ErrorStatement(_):
			case UninitializedDeclaration(name, _, _):
				aliases.remove(name);
			case VarDeclaration(name, _, e, _):
				scanCallExpression(e, calls, aliases);
				rememberAlias(name, e, aliases);
			case Assignment(name, e, _):
				scanCallExpression(e, calls, aliases);
				rememberAlias(name, e, aliases);
			case IndexAssignment(array, offset, e, _):
				scanCallExpression(array, calls, aliases);
				scanCallExpression(offset, calls, aliases);
				scanCallExpression(e, calls, aliases);
			case FieldAssignment(object, _, e, _):
				scanCallExpression(object, calls, aliases);
				scanCallExpression(e, calls, aliases);
			case Return(e, _):
				scanCallExpression(e, calls, aliases);
			case Throw(e, _):
				scanCallExpression(e, calls, aliases);
			case Try(tryBranch, catches, _):
				for (s in tryBranch)
					scanCalls(s, calls, aliases);
				for (catchClause in catches)
					for (s in catchClause.statements)
						scanCalls(s, calls, aliases);
			case ReturnVoid(_):
			case Break(_), Continue(_):
			case Increment(_, _, _):
			case If(c, y, n, _):
				scanCallExpression(c, calls, aliases);
				for (s in y)
					scanCalls(s, calls, aliases);
				for (s in n)
					scanCalls(s, calls, aliases);
			case While(c, b, _):
				scanCallExpression(c, calls, aliases);
				for (s in b)
					scanCalls(s, calls, aliases);
			case DoWhile(b, c, _):
				for (s in b)
					scanCalls(s, calls, aliases);
				scanCallExpression(c, calls, aliases);
			case ForIn(_, _, iterable, b, _):
				scanCallExpression(iterable, calls, aliases);
				for (s in b)
					scanCalls(s, calls, aliases);
			case Switch(expression, cases, defaultBranch, _, _):
				scanCallExpression(expression, calls, aliases);
				for (switchCase in cases) {
					scanCallExpression(switchCase.value, calls, aliases);
					var guard = switchCase.guard;
					if (guard != null)
						scanCallExpression(guard, calls, aliases);
					for (s in switchCase.statements)
						scanCalls(s, calls, aliases);
				}
				for (s in defaultBranch)
					scanCalls(s, calls, aliases);
			case Expression(e, _):
				scanCallExpression(e, calls, aliases);
		}

	public static function scanCallExpression(e:AstExpression, calls:Map<String, Bool>, aliases:Map<String, String>):Void
		switch e {
			case Call(name, args, _):
				var target = aliases.exists(name) ? aliases.get(name) : name;
				calls.set(target, true);
				for (a in args)
					scanCallExpression(a, calls, aliases);
			case MethodCall(object, _, args, _):
				scanCallExpression(object, calls, aliases);
				for (a in args)
					scanCallExpression(a, calls, aliases);
			case Member(object, _, _):
				scanCallExpression(object, calls, aliases);
			case Variable(name, _):
				if (name.indexOf(".") >= 0)
					calls.set(name, true);
			case Add(a, b, _), Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), BitAnd(a, b, _), BitXor(a, b, _), BitOr(a, b, _), ShiftLeft(a, b, _),
				ShiftRight(a, b, _), UnsignedShiftRight(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _), GreaterEqual(a, b, _), Equal(a, b, _),
				NotEqual(a, b, _):
				scanCallExpression(a, calls, aliases);
				scanCallExpression(b, calls, aliases);
			case Not(value, _):
				scanCallExpression(value, calls, aliases);
			case Negate(value, _):
				scanCallExpression(value, calls, aliases);
			case And(left, right, _), Or(left, right, _):
				scanCallExpression(left, calls, aliases);
				scanCallExpression(right, calls, aliases);
			case Conditional(predicate, whenTrue, whenFalse, _):
				scanCallExpression(predicate, calls, aliases);
				scanCallExpression(whenTrue, calls, aliases);
				scanCallExpression(whenFalse, calls, aliases);
			case BlockExpression(statements, value, _):
				for (statement in statements)
					scanCalls(statement, calls, aliases);
				scanCallExpression(value, calls, aliases);
			case ThrowExpression(value, _):
				scanCallExpression(value, calls, aliases);
			case Cast(value, _, _):
				scanCallExpression(value, calls, aliases);
			case SwitchExpression(subject, cases, fallback, _):
				scanCallExpression(subject, calls, aliases);
				for (switchCase in cases) {
					scanCallExpression(switchCase.value, calls, aliases);
					var guard = switchCase.guard;
					if (guard != null)
						scanCallExpression(guard, calls, aliases);
					scanCallExpression(switchCase.result, calls, aliases);
				}
				var fallbackExpression = fallback;
				if (fallbackExpression != null)
					scanCallExpression(fallbackExpression, calls, aliases);
			case ObjectLiteral(fields, _):
				for (field in fields)
					scanCallExpression(field.value, calls, aliases);
			case ArrayLiteral(values, _):
				for (value in values)
					scanCallExpression(value, calls, aliases);
			case MapLiteral(entries, _):
				for (mapEntry in entries) {
					scanCallExpression(mapEntry.key, calls, aliases);
					scanCallExpression(mapEntry.value, calls, aliases);
				}
			case ArrayComprehension(_, _, iterable, predicate, value, _):
				scanCallExpression(iterable, calls, aliases);
				if (predicate != null)
					scanCallExpression(predicate, calls, aliases);
				scanCallExpression(value, calls, aliases);
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				scanCallExpression(iterable, calls, aliases);
				if (predicate != null)
					scanCallExpression(predicate, calls, aliases);
				scanCallExpression(key, calls, aliases);
				scanCallExpression(value, calls, aliases);
			case Range(start, rangeEnd, _):
				scanCallExpression(start, calls, aliases);
				scanCallExpression(rangeEnd, calls, aliases);
			case New(typeName, args, _):
				calls.set(typeName + ".new", true);
				for (a in args)
					scanCallExpression(a, calls, aliases);
			case NewGeneric(typeName, _, args, _):
				calls.set(typeName + ".new", true);
				for (a in args)
					scanCallExpression(a, calls, aliases);
			case NewArray(_, length, _):
				scanCallExpression(length, calls, aliases);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				scanCallExpression(array, calls, aliases);
				scanCallExpression(offset, calls, aliases);
			case PostfixIncrement(target, _, _):
				scanCallExpression(target, calls, aliases);
			case Lambda(_, body, _):
				for (statement in body)
					scanCalls(statement, calls, aliases);
			default:
		}

	public static function rememberAlias(name:String, expression:AstExpression, aliases:Map<String, String>):Void
		switch expression {
			case Variable(target, _):
				var resolved = aliases.exists(target) ? aliases.get(target) : target;
				aliases.set(name, resolved);
			default:
				aliases.remove(name);
		}
}
