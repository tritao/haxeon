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
						methods: [
							for (method in classDecl.methods)
								inferFunction(inferFieldBoundArguments(method, classDecl), enums)
						],
						span: classDecl.span
					}
			],
			functions: [for (fn in program.functions) inferFunction(fn, enums)]
		};
	}

	static function inferFunction(fn:AstFunction, enums:Map<String, AstEnum>):AstFunction {
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
					var candidate = inferExpression(expression, environment, enums);
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

	static function inferExpression(expression:AstExpression, environment:Map<String, AstType>, enums:Map<String, AstEnum>):Null<AstType>
		return switch expression {
			case IntegerLiteral(_, _): IntType;
			case FloatLiteral(_, _): FloatType;
			case StringLiteral(_, _): StringType;
			case BoolLiteral(_, _): BoolType;
			case Variable(name, _): environment.get(name);
			case New(name, _, _): NamedType(name);
			case NewArray(element, _, _): ArrayType(element);
			case SwitchExpression(subject, cases, fallback, _):
				var subjectType = inferExpression(subject, environment, enums),
					inferred:Null<AstType> = null;
				for (switchCase in cases) {
					var caseEnvironment = copyTypes(environment);
					bindPattern(switchCase.value, subjectType, caseEnvironment, enums);
					var candidate = inferExpression(switchCase.result, caseEnvironment, enums);
					if (candidate != null && (inferred == null || sameType(inferred, candidate)))
						inferred = candidate;
				}
				if (fallback != null) {
					var candidate = inferExpression(fallback, environment, enums);
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
