package compiler.types;

import compiler.Ast.AstClass;
import compiler.Ast.AstArgument;
import compiler.Ast.AstEnum;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;

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
				typeParameters: classDecl.typeParameters,
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
			inferredFunctions.push(inferFunction(fn, enums));
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
				var environment:Map<String, AstType> = [];
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
			inferred.push(inferFunction(method, enums, byName));
		}
		return inferred;
	}

	static function constraintsFor(constraints:Map<String, Map<String, AstType>>, name:String):Map<String, AstType>
		return constraints.exists(name) ? constraints.get(name) : [];

	static function collectCallConstraints(statements:Array<AstStatement>, environment:Map<String, AstType>, methods:Map<String, AstFunction>,
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
					collectCallConstraints(yes, copyTypes(environment), methods, constraints);
					collectCallConstraints(no, copyTypes(environment), methods, constraints);
				case While(predicate, body, _), DoWhile(body, predicate, _):
					collectExpressionCallConstraint(predicate, environment, methods, constraints);
					collectCallConstraints(body, copyTypes(environment), methods, constraints);
				case ForIn(_, _, iterable, body, _):
					collectExpressionCallConstraint(iterable, environment, methods, constraints);
					collectCallConstraints(body, copyTypes(environment), methods, constraints);
				case Try(body, catches, _):
					collectCallConstraints(body, copyTypes(environment), methods, constraints);
					for (clause in catches)
						collectCallConstraints(clause.statements, copyTypes(environment), methods, constraints);
				case Switch(expression, cases, fallback, _, _):
					collectExpressionCallConstraint(expression, environment, methods, constraints);
					for (switchCase in cases)
						collectCallConstraints(switchCase.statements, copyTypes(environment), methods, constraints);
					collectCallConstraints(fallback, copyTypes(environment), methods, constraints);
				default:
			}

	static function collectExpressionCallConstraint(expression:AstExpression, environment:Map<String, AstType>, methods:Map<String, AstFunction>,
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
			default:
		}

	static function inferSimpleExpression(expression:AstExpression, environment:Map<String, AstType>):Null<AstType>
		return switch expression {
			case Variable(name, _): environment.get(name);
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case StringLiteral(_, _): StringType;
			case BoolLiteral(_, _): BoolType;
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

	static function inferFunction(fn:AstFunction, enums:Map<String, AstEnum>, ?methods:Map<String, AstFunction>):AstFunction {
		if (fn.result != InferredType)
			return fn;
		var environment:Map<String, AstType> = [];
		for (argument in fn.arguments)
			if (argument.type != InferredType)
				environment.set(argument.name, argument.type);
		var inferred:Null<AstType> = null;
		for (statement in fn.statements)
			switch statement {
				case Return(expression, _):
					var candidate = inferExpression(expression, environment, enums, methods);
					if (candidate != null && (inferred == null || sameType(inferred, candidate)))
						inferred = candidate;
				default:
			}
		if (inferred == null)
			return fn;
		return {
			name: fn.name,
			isStatic: fn.isStatic,
			typeParameters: fn.typeParameters,
			arguments: fn.arguments,
			result: inferred,
			statements: fn.statements,
			span: fn.span
		};
	}

	static function inferExpression(expression:AstExpression, environment:Map<String, AstType>, enums:Map<String, AstEnum>,
			?methods:Map<String, AstFunction>):Null<AstType>
		return switch expression {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case StringLiteral(_, _): StringType;
			case BoolLiteral(_, _): BoolType;
			case Variable(name, _): environment.get(name);
			case New(name, _, _): NamedType(name);
			case NewGeneric(name, typeArguments, _, _): AppliedType(name, typeArguments);
			case NewArray(element, _, _): ArrayType(element);
			case Call(name, _, _): var method = methods == null ? null : methods.get(localMethodName(name)); method == null || method.result == InferredType ? null : method.result;
			case SwitchExpression(subject, cases, fallback, _):
				var subjectType = inferExpression(subject, environment, enums, methods),
					inferred:Null<AstType> = null;
				for (switchCase in cases) {
					var caseEnvironment = copyTypes(environment);
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

	static function bindPattern(pattern:AstExpression, subjectType:Null<AstType>, environment:Map<String, AstType>, enums:Map<String, AstEnum>):Void {
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
		return Std.string(left) == Std.string(right);

	static function localMethodName(name:String):String
		return lastPathSegment(name);

	static function copyTypes(source:Map<String, AstType>):Map<String, AstType> {
		var result:Map<String, AstType> = [];
		for (name => type in source)
			result.set(name, type);
		return result;
	}

	public static function inferFieldBoundArguments(fn:AstFunction, classDecl:AstClass):AstFunction {
		var inferred:Map<String, AstType> = [];
		for (statement in fn.statements)
			switch statement {
				case FieldAssignment(object, fieldName, value, _):
					switch object {
						case Variable(objectName, _) if (objectName == "this"):
							switch value {
								case Variable(argumentName, _): constrainFromField(inferred, argumentName, fieldName, classDecl);
								default:
							}
						default:
					}
				case Assignment(fieldPath, value, _) if (StringTools.startsWith(fieldPath, "this.")):
					switch value {
						case Variable(argumentName, _):
							constrainFromField(inferred, argumentName, fieldPath.substring("this.".length, fieldPath.length), classDecl);
						default:
					}
				default:
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
