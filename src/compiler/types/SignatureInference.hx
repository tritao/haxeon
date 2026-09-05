package compiler.types;

import compiler.Ast.AstClass;
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
		return {
			packageName: program.packageName,
			imports: program.imports,
			importAliases: program.importAliases,
			aliases: program.aliases,
			enums: program.enums,
			enumAbstracts: program.enumAbstracts,
			abstracts: program.abstracts,
			interfaces: program.interfaces,
			classes: [
				for (classDecl in program.classes)
					{
						name: classDecl.name,
						isPrivate: classDecl.isPrivate,
						metadata: classDecl.metadata,
						base: classDecl.base,
						interfaces: classDecl.interfaces,
						fields: classDecl.fields,
						methods: inferClassMethods(classDecl, enums, constructors, classes),
						span: classDecl.span
					}
			],
			functions: [for (fn in program.functions) inferFunction(fn, enums)]
		};
	}

	static function inferClassMethods(classDecl:AstClass, enums:Map<String, AstEnum>, constructors:Map<String, AstFunction>,
			classes:Map<String, AstClass>):Array<AstFunction> {
		var methods = [for (method in classDecl.methods) inferFieldBoundArguments(method, classDecl)],
			byName:Map<String, AstFunction> = [];
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
					replaceArguments(method, calleeConstraints.get(method.name) == null ? [] : calleeConstraints.get(method.name))
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
		return [for (method in constrained) inferFunction(method, enums, byName)];
	}

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
				case If(condition, yes, no, _):
					collectExpressionCallConstraint(condition, environment, methods, constraints);
					collectCallConstraints(yes, copyTypes(environment), methods, constraints);
					collectCallConstraints(no, copyTypes(environment), methods, constraints);
				case While(condition, body, _), DoWhile(body, condition, _):
					collectExpressionCallConstraint(condition, environment, methods, constraints);
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
				var methodName = localMethodName(name),
					callee = methods.get(methodName);
				if (callee != null) {
					var inferred = constraints.get(methodName);
					if (inferred == null) {
						inferred = [];
						constraints.set(methodName, inferred);
					}
					for (index in 0...arguments.length)
						if (index < callee.arguments.length && callee.arguments[index].type == InferredType)
							switch arguments[index] {
								case Variable(argumentName, _):
									var type = environment.get(argumentName);
									if (type != null) inferred.set(callee.arguments[index].name, type);
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
			case NewArray(element, _, _): ArrayType(element);
			default: null;
		};

	static function inferCallBoundArguments(fn:AstFunction, owner:AstClass, methods:Map<String, AstFunction>, constructors:Map<String, AstFunction>,
			classes:Map<String, AstClass>):AstFunction {
		var inferred:Map<String, AstType> = [];
		for (statement in fn.statements)
			switch statement {
				case Assignment(path, Variable(argumentName, _), _):
					var fieldType = resolveMemberPath(path, owner, classes);
					switch fieldType {
						case NullableType(element): inferred.set(argumentName, element);
						case null:
						default: inferred.set(argumentName, fieldType);
					}
				case Return(Call(name, arguments, _), _), Expression(Call(name, arguments, _), _):
					var callee = methods.get(localMethodName(name));
					if (callee != null)
						for (index in 0...arguments.length)
							if (index < callee.arguments.length && callee.arguments[index].type != InferredType)
								switch arguments[index] {
									case Variable(argumentName, _): inferred.set(argumentName, callee.arguments[index].type);
									default:
								}
					if (StringTools.endsWith(name, ".push") && arguments.length == 1) {
						var receiverPath = name.substr(0, name.length - ".push".length),
							receiverType = resolveMemberPath(receiverPath, owner, classes);
						switch [receiverType, arguments[0]] {
							case [ArrayType(element), Variable(argumentName, _)]: inferred.set(argumentName, element);
							default:
						}
					}
				case Return(MethodCall(_, name, arguments, _), _), Expression(MethodCall(_, name, arguments, _), _):
					var callee = methods.get(name);
					if (callee != null)
						for (index in 0...arguments.length)
							if (index < callee.arguments.length && callee.arguments[index].type != InferredType)
								switch arguments[index] {
									case Variable(argumentName, _): inferred.set(argumentName, callee.arguments[index].type);
									default:
								}
				case Return(New(name, arguments, _), _), Expression(New(name, arguments, _), _):
					var constructor = constructors.get(name);
					if (constructor != null)
						for (index in 0...arguments.length)
							if (index < constructor.arguments.length && constructor.arguments[index].type != InferredType)
								switch arguments[index] {
									case Variable(argumentName, _): inferred.set(argumentName, constructor.arguments[index].type);
									default:
								}
				default:
			}
		return replaceArguments(fn, inferred);
	}

	static function resolveMemberPath(path:String, owner:AstClass, classes:Map<String, AstClass>):Null<AstType> {
		var parts = path.split("."), current:Null<AstType> = null;
		for (field in owner.fields)
			if (field.name == parts[0])
				current = field.type;
		for (index in 1...parts.length)
			switch current {
				case NamedType(className):
					var classDecl = classes.get(className);
					current = null;
					if (classDecl != null)
						for (field in classDecl.fields)
							if (field.name == parts[index])
								current = field.type;
				default:
					current = null;
			}
		return current;
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
		var enumName = switch subjectType {
			case NamedType(name): name;
			default: null;
		};
		if (enumName == null)
			return;
		var enumDecl = enums.get(enumName);
		if (enumDecl == null)
			return;
		switch pattern {
			case Call(name, arguments, _):
				var separator = name.lastIndexOf("."),
					caseName = separator < 0 ? name : name.substr(separator + 1);
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

	static function sameType(left:AstType, right:AstType):Bool
		return Std.string(left) == Std.string(right);

	static function localMethodName(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substr(separator + 1);
	}

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
				case FieldAssignment(Variable("this", _), fieldName, Variable(argumentName, _), _):
					constrainFromField(inferred, argumentName, fieldName, classDecl);
				case Assignment(fieldPath, Variable(argumentName, _), _) if (StringTools.startsWith(fieldPath, "this.")):
					constrainFromField(inferred, argumentName, fieldPath.substr("this.".length), classDecl);
				default:
			}
		return replaceArguments(fn, inferred);
	}

	static function replaceArguments(fn:AstFunction, inferred:Map<String, AstType>):AstFunction {
		var changed = false, arguments = [
			for (argument in fn.arguments) {
				var inferredType = argument.type == InferredType ? inferred.get(argument.name) : null;
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
			if (field.name == fieldName && field.type != null)
				inferred.set(argumentName, field.type);
}
