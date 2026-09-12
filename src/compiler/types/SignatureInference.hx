package compiler.types;

import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

/** Lexically scoped types used while collecting lightweight signature constraints. */
private class InferenceEnvironment {
	final parent:Null<InferenceEnvironment>;
	final values:Map<String, AstType> = [];

	public function new(?parent)
		this.parent = parent;

	public function fork():InferenceEnvironment
		return new InferenceEnvironment(this);

	public function set(name:String, type:AstType):Void
		values.set(name, type);

	public function get(name:String):Null<AstType>
		return values.exists(name) ? values.get(name) : parent == null ? null : parent.get(name);

	public function exists(name:String):Bool
		return values.exists(name) || parent != null && parent.exists(name);
}

/** Collects declaration-level constraints before body typing. */
class SignatureInference {
	public static function inferProgram(program:AstProgram):AstProgram {
		var enums:Map<String, AstEnum> = [];
		for (enumDecl in program.enums)
			enums.set(enumDecl.name, enumDecl);
		var constructors:Map<String, AstFunction> = [];
		var classes:Map<String, AstClass> = [];
		for (classDecl in program.classes) {
			classes.set(classDecl.name, classDecl);
			for (method in classDecl.methods)
				if (method.name == "new")
					constructors.set(classDecl.name, inferFieldBoundArguments(method, classDecl));
		}
		var inferredClasses:Array<AstClass> = [];
		for (classDecl in program.classes) {
			inferredClasses.push({
				name: classDecl.name,
				isExtern: classDecl.isExtern,
				typeParameters: classDecl.typeParameters,
				typeConstraints: classDecl.typeConstraints,
				isPrivate: classDecl.isPrivate,
				metadata: classDecl.metadata,
				base: classDecl.base,
				interfaces: classDecl.interfaces,
				fields: classDecl.fields,
				methods: inferClassMethods(classDecl, enums, constructors, classes),
				span: classDecl.span
			});
		}
		var inferredFunctions:Array<AstFunction> = [];
		for (fn in program.functions) {
			inferredFunctions.push(inferFunction(inferDefaultBoundArguments(fn), enums));
		}
		return {
			packageName: program.packageName,
			imports: program.imports,
			importAliases: program.importAliases,
			aliases: program.aliases,
			enums: program.enums,
			enumAbstracts: program.enumAbstracts,
			abstracts: program.abstracts,
			interfaces: program.interfaces,
			classes: inferredClasses,
			functions: inferredFunctions
		};
	}

	static function inferClassMethods(classDecl:AstClass, enums:Map<String, AstEnum>, constructors:Map<String, AstFunction>,
			classes:Map<String, AstClass>):Array<AstFunction> {
		var methods:Array<AstFunction> = [],
			byName:Map<String, AstFunction> = [];
		for (method in classDecl.methods) {
			methods.push(inferFieldBoundArguments(method, classDecl));
		}
		for (method in methods)
			byName.set(method.name, method);
		for (_ in 0...methods.length) {
			var calleeConstraints:Map<String, Map<String, AstType>> = [];
			for (method in methods) {
				var environment = new InferenceEnvironment();
				for (argument in method.arguments)
					if (argument.type != InferredType)
						environment.set(argument.name, argument.type);
				collectCallConstraints(method.statements, environment, byName, calleeConstraints);
			}
			methods = [
				for (method in methods)
					replaceArguments(method, constraintsFor(calleeConstraints, method.name))
			];
			for (method in methods)
				byName.set(method.name, method);
		}
		var constrained = [
			for (method in methods)
				inferCallBoundArguments(method, classDecl, byName, constructors, classes)
		];
		for (method in constrained)
			byName.set(method.name, method);
		var inferred:Array<AstFunction> = [];
		for (method in constrained) {
			inferred.push(inferFunction(method, enums, byName, classDecl));
		}
		return inferred;
	}

	static function constraintsFor(constraints:Map<String, Map<String, AstType>>, name:String):Map<String, AstType>
		return constraints.exists(name) ? constraints.get(name) : [];

	static function collectCallConstraints(statements:Array<AstStatement>, environment:InferenceEnvironment, methods:Map<String, AstFunction>,
			constraints:Map<String, Map<String, AstType>>):Void
		for (statement in statements)
			switch statement {
				case VarDeclaration(name, type, initializer, _):
					var valueType = type == null ? inferSimpleExpression(initializer, environment) : type;
					if (valueType != null)
						environment.set(name, valueType);
					collectExpressionCallConstraint(initializer, environment, methods, constraints);
				case Return(expression, _), Expression(expression, _), Throw(expression, _):
					collectExpressionCallConstraint(expression, environment, methods, constraints);
				case If(predicate, yes, no, _):
					collectExpressionCallConstraint(predicate, environment, methods, constraints);
					collectCallConstraints(yes, environment.fork(), methods, constraints);
					collectCallConstraints(no, environment.fork(), methods, constraints);
				case While(predicate, body, _), DoWhile(body, predicate, _):
					collectExpressionCallConstraint(predicate, environment, methods, constraints);
					collectCallConstraints(body, environment.fork(), methods, constraints);
				case ForIn(_, _, iterable, body, _):
					collectExpressionCallConstraint(iterable, environment, methods, constraints);
					collectCallConstraints(body, environment.fork(), methods, constraints);
				case Try(body, catches, _):
					collectCallConstraints(body, environment.fork(), methods, constraints);
					for (clause in catches)
						collectCallConstraints(clause.statements, environment.fork(), methods, constraints);
				case Switch(expression, cases, fallback, _, _):
					collectExpressionCallConstraint(expression, environment, methods, constraints);
					for (switchCase in cases)
						collectCallConstraints(switchCase.statements, environment.fork(), methods, constraints);
					collectCallConstraints(fallback, environment.fork(), methods, constraints);
				default:
			}

	static function collectExpressionCallConstraint(expression:AstExpression, environment:InferenceEnvironment, methods:Map<String, AstFunction>,
			constraints:Map<String, Map<String, AstType>>):Void
		switch expression {
			case Call(name, arguments, _), MethodCall(_, name, arguments, _):
				var methodName = localMethodName(name);
				if (methods.exists(methodName)) {
					var callee = methods.get(methodName),
						inferred:Map<String, AstType>;
					if (constraints.exists(methodName))
						inferred = constraints.get(methodName);
					else {
						inferred = [];
						constraints.set(methodName, inferred);
					}
					for (index in 0...arguments.length)
						if (index < callee.arguments.length && callee.arguments[index].type == InferredType)
							switch arguments[index] {
								case Variable(argumentName, _):
									if (environment.exists(argumentName)) inferred.set(callee.arguments[index].name, environment.get(argumentName));
								default:
							}
				}
			case ClosureCall(callee, arguments, _):
				collectExpressionCallConstraint(callee, environment, methods, constraints);
				for (argument in arguments)
					collectExpressionCallConstraint(argument, environment, methods, constraints);
			default:
		}

	static function inferSimpleExpression(expression:AstExpression, environment:InferenceEnvironment):Null<AstType>
		return switch expression {
			case Variable(name, _): environment.get(name);
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case StringLiteral(_, _): StringType;
			case BoolLiteral(_, _): BoolType;
			case Less(_, _, _), LessEqual(_, _, _), Greater(_, _, _), GreaterEqual(_, _, _), Equal(_, _, _), NotEqual(_, _, _), Not(_, _), And(_, _, _),
				Or(_, _, _):
				BoolType;
			case New(name, _, _): NamedType(name);
			case NewGeneric(name, typeArguments, _, _): AppliedType(name, typeArguments);
			case NewArray(element, _, _): ArrayType(element);
			default: null;
		};

	static function inferCallBoundArguments(fn:AstFunction, owner:AstClass, methods:Map<String, AstFunction>, constructors:Map<String, AstFunction>,
			classes:Map<String, AstClass>):AstFunction {
		var inferred:Map<String, AstType> = [];
		for (statement in fn.statements)
			switch statement {
				case Assignment(path, value, _):
					switch value {
						case Variable(argumentName, _): inferAssignmentBoundArgument(path, argumentName, owner, classes, inferred);
						default:
					}
				case Return(expression, _), Expression(expression, _):
					inferExpressionBoundArguments(expression, owner, methods, constructors, classes, inferred);
				default:
			}
		return replaceArguments(fn, inferred);
	}

	static function inferAssignmentBoundArgument(path:String, argumentName:String, owner:AstClass, classes:Map<String, AstClass>,
			inferred:Map<String, AstType>):Void {
		var fieldType = resolveMemberPath(path, owner, classes);
		if (fieldType == null)
			return;
		switch fieldType {
			case NullableType(element):
				inferred.set(argumentName, element);
			default:
				inferred.set(argumentName, fieldType);
		}
	}

	static function inferExpressionBoundArguments(expression:AstExpression, owner:AstClass, methods:Map<String, AstFunction>,
			constructors:Map<String, AstFunction>, classes:Map<String, AstClass>, inferred:Map<String, AstType>):Void
		switch expression {
			case Call(name, arguments, _):
				inferArgumentsFromCallable(methods, localMethodName(name), arguments, inferred);
				if (StringTools.endsWith(name, ".push") && arguments.length == 1) {
					var receiverPath = name.substring(0, name.length - ".push".length),
						receiverType = resolveMemberPath(receiverPath, owner, classes);
					if (receiverType != null)
						switch receiverType {
							case ArrayType(element):
								switch arguments[0] {
									case Variable(argumentName, _): inferred.set(argumentName, element);
									default:
								}
							default:
						}
				}
			case MethodCall(_, name, arguments, _):
				inferArgumentsFromCallable(methods, name, arguments, inferred);
			case New(name, arguments, _), NewGeneric(name, _, arguments, _):
				inferArgumentsFromCallable(constructors, name, arguments, inferred);
			default:
		}

	static function inferArgumentsFromCallable(callables:Map<String, AstFunction>, name:String, arguments:Array<AstExpression>,
			inferred:Map<String, AstType>):Void {
		if (!callables.exists(name))
			return;
		var callable = callables.get(name);
		for (index in 0...arguments.length)
			if (index < callable.arguments.length && callable.arguments[index].type != InferredType)
				switch arguments[index] {
					case Variable(argumentName, _):
						inferred.set(argumentName, callable.arguments[index].type);
					default:
				}
	}

	static function resolveMemberPath(path:String, owner:AstClass, classes:Map<String, AstClass>):Null<AstType> {
		var parts = splitPath(path), current:Null<AstType> = null;
		for (field in owner.fields)
			if (field.name == parts[0])
				current = field.type;
		for (index in 1...parts.length) {
			var resolved = current;
			if (resolved == null)
				return null;
			switch resolved {
				case NamedType(className):
					current = null;
					if (classes.exists(className)) {
						var classDecl = classes.get(className);
						for (field in classDecl.fields)
							if (field.name == parts[index])
								current = field.type;
					}
				default:
					current = null;
			}
		}
		return current;
	}

	static function splitPath(path:String):Array<String> {
		return compiler.QualifiedName.split(path);
	}

	static function inferFunction(fn:AstFunction, enums:Map<String, AstEnum>, ?methods:Map<String, AstFunction>, ?owner:AstClass):AstFunction {
		if (fn.result != InferredType)
			return fn;
		var environment = new InferenceEnvironment();
		for (argument in fn.arguments)
			if (argument.type != InferredType)
				environment.set(argument.name, argument.type);
		if (owner != null)
			for (field in owner.fields)
				environment.set(field.name, field.type);
		var candidates:Array<AstType> = [];
		var hasValueReturn = collectReturnTypes(fn.statements, environment, enums, methods, candidates);
		if (candidates.length == 0)
			return hasValueReturn ? fn : withResult(fn, VoidType);
		var inferred:Null<AstType> = candidates[0];
		for (candidate in candidates)
			if (!sameType(inferred, candidate))
				return fn;
		if (inferred == null)
			return fn;
		return withResult(fn, inferred);
	}

	static function withResult(fn:AstFunction, result:AstType):AstFunction
		return {
			name: fn.name,
			isStatic: fn.isStatic,
			typeParameters: fn.typeParameters,
			typeConstraints: fn.typeConstraints,
			arguments: fn.arguments,
			result: result,
			statements: fn.statements,
			span: fn.span
		};

	static function collectReturnTypes(statements:Array<AstStatement>, environment:InferenceEnvironment, enums:Map<String, AstEnum>,
			methods:Null<Map<String, AstFunction>>, output:Array<AstType>):Bool {
		var found = false;
		for (statement in statements)
			switch statement {
				case Return(expression, _):
					found = true;
					var candidate = inferExpression(expression, environment, enums, methods);
					if (candidate != null)
						output.push(candidate);
				case If(_, yes, no, _):
					found = collectReturnTypes(yes, environment, enums, methods, output) || found;
					found = collectReturnTypes(no, environment, enums, methods, output) || found;
				case Try(body, catches, _):
					found = collectReturnTypes(body, environment, enums, methods, output) || found;
					for (clause in catches)
						found = collectReturnTypes(clause.statements, environment, enums, methods, output) || found;
				case While(_, body, _), DoWhile(body, _, _), ForIn(_, _, _, body, _):
					found = collectReturnTypes(body, environment, enums, methods, output) || found;
				case Switch(_, cases, fallback, _, _):
					for (switchCase in cases)
						found = collectReturnTypes(switchCase.statements, environment, enums, methods, output) || found;
					found = collectReturnTypes(fallback, environment, enums, methods, output) || found;
				default:
			}
		return found;
	}

	static function inferExpression(expression:AstExpression, environment:InferenceEnvironment, enums:Map<String, AstEnum>,
			?methods:Map<String, AstFunction>):Null<AstType>
		return switch expression {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case StringLiteral(_, _): StringType;
			case BoolLiteral(_, _): BoolType;
			case Less(_, _, _), LessEqual(_, _, _), Greater(_, _, _), GreaterEqual(_, _, _), Equal(_, _, _), NotEqual(_, _, _), Not(_, _), And(_, _, _),
				Or(_, _, _):
				BoolType;
			case Variable(name, _): environment.get(name);
			case New(name, _, _): NamedType(name);
			case NewGeneric(name, typeArguments, _, _): AppliedType(name, typeArguments);
			case NewArray(element, _, _): ArrayType(element);
			case Call(name, _, _):
				var method = methods == null ? null : methods.get(localMethodName(name));
				if (method != null && method.result != InferredType) method.result; else inferQualifiedCollectionCall(name, environment);
			case ClosureCall(callee, _, _): switch inferExpression(callee, environment, enums, methods) {
					case FunctionType(_, result): result;
					default: null;
				};
			case MethodCall(object, name, _, _): inferCollectionMethod(inferExpression(object, environment, enums, methods), name);
			case SwitchExpression(subject, cases, fallback, _):
				var subjectType = inferExpression(subject, environment, enums, methods),
					inferred:Null<AstType> = null;
				for (switchCase in cases) {
					var caseEnvironment = environment.fork();
					bindPattern(switchCase.value, subjectType, caseEnvironment, enums);
					var candidate = inferExpression(switchCase.result, caseEnvironment, enums, methods);
					if (candidate != null && (inferred == null || sameType(inferred, candidate)))
						inferred = candidate;
				}
				if (fallback != null) {
					var candidate = inferExpression(fallback, environment, enums, methods);
					if (candidate != null && (inferred == null || sameType(inferred, candidate)))
						inferred = candidate;
				}
				inferred;
			default: null;
		};

	static function inferQualifiedCollectionCall(name:String, environment:InferenceEnvironment):Null<AstType> {
		var parts = splitPath(name);
		if (parts.length != 2 || !environment.exists(parts[0]))
			return null;
		return inferCollectionMethod(environment.get(parts[0]), parts[1]);
	}

	static function inferCollectionMethod(receiver:Null<AstType>, name:String):Null<AstType>
		return switch receiver {
			case MapType(_, value) if (name == "get"): NullableType(value);
			case MapType(key, _) if (name == "keys"): AppliedType("Iterator", [key]);
			case MapType(_, value) if (name == "values"): AppliedType("Iterator", [value]);
			case MapType(_, _) if (name == "exists" || name == "remove"): BoolType;
			case ArrayType(element) if (name == "iterator"): AppliedType("Iterator", [element]);
			case AppliedType("List", [element]) if (name == "iterator"): AppliedType("Iterator", [element]);
			default: null;
		};

	static function bindPattern(pattern:AstExpression, subjectType:Null<AstType>, environment:InferenceEnvironment, enums:Map<String, AstEnum>):Void {
		if (subjectType == null)
			return;
		var enumName = switch subjectType {
			case NamedType(name): name;
			default: null;
		};
		if (enumName == null || !enums.exists(enumName))
			return;
		var enumDecl = enums.get(enumName);
		switch pattern {
			case Call(name, arguments, _):
				var caseName = lastPathSegment(name);
				for (caseDecl in enumDecl.cases)
					if (caseDecl.name == caseName)
						for (index in 0...arguments.length)
							switch arguments[index] {
								case Variable(binding, _) if (binding != "_" && index < caseDecl.params.length):
									environment.set(binding, caseDecl.params[index].type);
								default:
							}
			default:
		}
	}

	static function lastPathSegment(path:String):String {
		return compiler.QualifiedName.last(path);
	}

	static function sameType(left:AstType, right:AstType):Bool
		return switch left {
			case IntType: switch right {
					case IntType: true;
					default: false;
				};
			case BoolType: switch right {
					case BoolType: true;
					default: false;
				};
			case FloatType: switch right {
					case FloatType: true;
					default: false;
				};
			case StringType: switch right {
					case StringType: true;
					default: false;
				};
			case VoidType: switch right {
					case VoidType: true;
					default: false;
				};
			case InferredType: switch right {
					case InferredType: true;
					default: false;
				};
			case ErrorType(_): switch right {
					case ErrorType(_): true;
					default: false;
				};
			case NativeAbstractType(declaration, tag): switch right {
					case NativeAbstractType(otherDeclaration, otherTag): declaration == otherDeclaration && tag == otherTag;
					default: false;
				};
			case NamedType(name): switch right {
					case NamedType(other): name == other;
					default: false;
				};
			case AppliedType(name, arguments): switch right {
					case AppliedType(otherName, otherArguments): name == otherName && sameTypes(arguments, otherArguments);
					default: false;
				};
			case ArrayType(element): switch right {
					case ArrayType(other): sameType(element, other);
					default: false;
				};
			case MapType(key, value): switch right {
					case MapType(otherKey, otherValue): sameType(key, otherKey) && sameType(value, otherValue);
					default: false;
				};
			case NullableType(element): switch right {
					case NullableType(other): sameType(element, other);
					default: false;
				};
			case FunctionType(arguments, result): switch right {
					case FunctionType(otherArguments, otherResult): sameTypes(arguments, otherArguments) && sameType(result, otherResult);
					default: false;
				};
			case AnonymousType(fields): switch right {
					case AnonymousType(otherFields): sameFields(fields, otherFields);
					default: false;
				};
		};

	static function sameTypes(left:Array<AstType>, right:Array<AstType>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (!sameType(left[index], right[index]))
				return false;
		return true;
	}

	static function sameFields(left:Array<compiler.syntax.Ast.AstAnonymousField>, right:Array<compiler.syntax.Ast.AstAnonymousField>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length) {
			var field = left[index], other = right[index];
			if (field.name != other.name || field.optional != other.optional || !sameType(field.type, other.type))
				return false;
		}
		return true;
	}

	static function localMethodName(name:String):String
		return lastPathSegment(name);

	public static function inferFieldBoundArguments(fn:AstFunction, classDecl:AstClass):AstFunction {
		fn = inferDefaultBoundArguments(fn);
		var inferred:Map<String, AstType> = [];
		for (statement in fn.statements)
			switch statement {
				case FieldAssignment(object, fieldName, value, _):
					switch object {
						case Variable(objectName, _) if (objectName == "this"):
							constrainExpressionFromField(inferred, value, fieldName, classDecl);
						default:
					}
				case Assignment(fieldPath, value, _) if (StringTools.startsWith(fieldPath, "this.")):
					constrainExpressionFromField(inferred, value, fieldPath.substring("this.".length, fieldPath.length), classDecl);
				default:
			}
		return replaceArguments(fn, inferred);
	}

	static function constrainExpressionFromField(inferred:Map<String, AstType>, expression:AstExpression, fieldName:String, classDecl:AstClass):Void
		switch expression {
			case Variable(argumentName, _):
				constrainFromField(inferred, argumentName, fieldName, classDecl);
			case Conditional(_, whenTrue, whenFalse, _):
				constrainExpressionFromField(inferred, whenTrue, fieldName, classDecl);
				constrainExpressionFromField(inferred, whenFalse, fieldName, classDecl);
			case BlockExpression(_, result, _):
				constrainExpressionFromField(inferred, result, fieldName, classDecl);
			case Cast(value, null, _):
				constrainExpressionFromField(inferred, value, fieldName, classDecl);
			case SwitchExpression(_, cases, defaultExpression, _):
				for (switchCase in cases)
					constrainExpressionFromField(inferred, switchCase.result, fieldName, classDecl);
				if (defaultExpression != null)
					constrainExpressionFromField(inferred, defaultExpression, fieldName, classDecl);
			default:
		}

	static function inferDefaultBoundArguments(fn:AstFunction):AstFunction {
		var inferred:Map<String, AstType> = [];
		for (argument in fn.arguments)
			if (argument.type == InferredType && argument.defaultValue != null) {
				var defaultType = inferSimpleExpression(argument.defaultValue, new InferenceEnvironment());
				if (defaultType != null)
					inferred.set(argument.name, defaultType);
			}
		return replaceArguments(fn, inferred);
	}

	static function replaceArguments(fn:AstFunction, inferred:Map<String, AstType>):AstFunction {
		var changed = false, arguments:Array<AstArgument> = [
			for (argument in fn.arguments) {
				var inferredType = argument.type == InferredType && inferred.exists(argument.name) ? inferred.get(argument.name) : null;
				if (inferredType != null) changed = true;
				{
					name: argument.name,
					type: inferredType == null ? argument.type : inferredType,
					span: argument.span,
					optional: argument.optional,
					defaultValue: argument.defaultValue
				};
			}
		];
		return changed ? {
			name: fn.name,
			isStatic: fn.isStatic,
			typeParameters: fn.typeParameters,
			typeConstraints: fn.typeConstraints,
			arguments: arguments,
			result: fn.result,
			statements: fn.statements,
			span: fn.span
		} : fn;
	}

	static function constrainFromField(inferred:Map<String, AstType>, argumentName:String, fieldName:String, classDecl:AstClass):Void
		for (field in classDecl.fields)
			if (field.name == fieldName) {
				var fieldType = field.type;
				if (fieldType != null)
					inferred.set(argumentName, fieldType);
			}
}
