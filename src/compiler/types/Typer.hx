package compiler.types;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.Ast.AstClass;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;

class Typer {
	final signatures:Map<String, AstFunction> = [];
	final methodInfo:Map<String, {owner:String, isStatic:Bool, isConstructor:Bool}> = [];
	final externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>;
	var classDecls:Map<String, AstClass> = [];

	public static function type(program:AstProgram):TypedProgram
		return new Typer(null).typeProgram(program, null);

	public static function typeSelected(program:AstProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>):TypedProgram
		return new Typer(externals).typeProgram(program, selected);

	function new(externals)
		this.externals = externals == null ? [] : externals;

	function typeProgram(program:AstProgram, selected:Null<Map<String, Bool>>):TypedProgram {
		var classes:Map<String, AstClass> = [];
		for (classDecl in program.classes) {
			if (classes.exists(classDecl.name))
				fail("E1000", 'Duplicate class "${classDecl.name}"', classDecl.span);
			classes.set(classDecl.name, classDecl);
			for (method in classDecl.methods) {
				var qualified = classDecl.name + "." + method.name;
				if (signatures.exists(qualified))
					fail("E1000", 'Duplicate method "$qualified"', method.span);
				signatures.set(qualified, method);
				methodInfo.set(qualified, {
					owner: classDecl.name,
					isStatic: method.isStatic,
					isConstructor: method.name == "new"
				});
			}
		}
		classDecls = classes;
		for (fn in program.functions) {
			if (signatures.exists(fn.name))
				fail("E1000", 'Duplicate function "${fn.name}"', fn.span);
			if (externals.exists(fn.name))
				fail("E1000", 'Function "${fn.name}" conflicts with a registered native', fn.span);
			signatures.set(fn.name, fn);
		}
		var main = signatures.get("main");
		if (main == null || main.arguments.length != 0 || lowerType(main.result) != TInt)
			throw "Program must define function main():Int";
		var typedClasses = [for (classDecl in program.classes) typeClass(classDecl, classes)],
			typedFunctions:Array<TypedFunction> = [];
		for (fn in program.functions)
			if (selected == null || selected.exists(fn.name))
				typedFunctions.push(typeFunction(fn));
		for (classDecl in typedClasses)
			for (method in classDecl.methods)
				if (selected == null || selected.exists(method.name))
					typedFunctions.push(method);
		return {
			classes: typedClasses,
			functions: typedFunctions
		};
	}

	function typeClass(classDecl:AstClass, classes:Map<String, AstClass>):TypedClass {
		var fields = [], fieldNames:Map<String, Bool> = [];
		for (field in classDecl.fields) {
			if (fieldNames.exists(field.name))
				fail("E1000", 'Duplicate field "${classDecl.name}.${field.name}"', field.span);
			var type = lowerType(field.type);
			if (type == TVoid)
				fail("E1002", 'Field "${classDecl.name}.${field.name}" cannot have type Void', field.span);
			fieldNames.set(field.name, true);
			fields.push({
				name: field.name,
				type: type,
				isStatic: field.isStatic,
				isFinal: field.isFinal,
				span: field.span
			});
		}
		return {
			name: classDecl.name,
			base: classDecl.base,
			fields: fields,
			methods: [
				for (method in classDecl.methods)
					typeFunction(method, classDecl.name, method.isStatic)
			],
			span: classDecl.span
		};
	}

	function typeFunction(fn:AstFunction, ?owner:String, isStatic:Bool = false):TypedFunction {
		var scope = new Scope();
		var isConstructor = owner != null && fn.name == "new";
		if (owner != null && !isStatic)
			scope.define("this", TClass(owner), fn.span);
		var arguments = [];
		for (argument in fn.arguments) {
			var type = lowerType(argument.type);
			scope.define(argument.name, type, argument.span);
			arguments.push({name: argument.name, type: type});
		}
		var result = lowerType(fn.result);
		var statements = typeStatements(fn.statements, scope, result);
		if (result != TVoid && !alwaysReturns(statements))
			fail("E1006", 'Function ${fn.name} does not return on every path', fn.span);
		return {
			name: owner == null ? fn.name : owner + "." + fn.name,
			owner: owner,
			isStatic: isStatic,
			isConstructor: isConstructor,
			arguments: arguments,
			result: result,
			statements: statements,
			span: fn.span
		};
	}

	function typeStatements(statements:Array<AstStatement>, scope:Scope, result:CompilerType):Array<TypedStatement> {
		var output = [];
		for (statement in statements) {
			if (alwaysReturns(output))
				fail("E1012", "Unreachable statement", statementSpan(statement));
			switch statement {
				case VarDeclaration(name, declared, initializer, span):
					var value = typeExpression(initializer, scope);
					if (declared != null && lowerType(declared) != value.type)
						fail("E1002", 'Type mismatch for local "$name"', span);
					scope.define(name, value.type, span);
					output.push(TVar(name, value, span));
				case Return(expression, span):
					var value = typeExpression(expression, scope);
					if (!sameType(value.type, result))
						fail("E1003", "Return type mismatch", span);
					output.push(TReturn(value, span));
				case Assignment(name, expression, span):
					var dot = name.indexOf("."),
						value = typeExpression(expression, scope);
					if (dot < 0) {
						var expected = scope.resolve(name);
						if (expected == null)
							fail("E1005", 'Unknown variable "$name"', span);
						if (!sameType(value.type, expected))
							fail("E1002", 'Type mismatch for local "$name"', span);
						output.push(TAssign(name, value, span));
					} else {
						var objectName = name.substr(0, dot),
							fieldName = name.substr(dot + 1),
							object = typeExpression(Variable(objectName, span), scope),
							expected = fieldType(object.type, fieldName, span);
						if (!sameType(value.type, expected))
							fail("E1002", 'Type mismatch for field "$name"', span);
						output.push(TFieldAssign(object, fieldName, value, span));
					}
				case If(condition, thenBranch, elseBranch, span):
					var typedCondition = typeExpression(condition, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "If condition must be Bool", span);
					output.push(TIf(typedCondition, typeStatements(thenBranch, new Scope(scope), result),
						typeStatements(elseBranch, new Scope(scope), result), span));
				case While(condition, body, span):
					var typedCondition = typeExpression(condition, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "While condition must be Bool", span);
					output.push(TWhile(typedCondition, typeStatements(body, new Scope(scope), result), span));
				case Expression(expression, span):
					output.push(TExpression(typeExpression(expression, scope), span));
			}
		}
		return output;
	}

	function typeExpression(expression:AstExpression, scope:Scope):TypedExpression
		return switch expression {
			case IntegerLiteral(value, span): new TypedExpression(TIntLiteral(value), TInt, span);
			case FloatLiteral(value, span): new TypedExpression(TFloatLiteral(value), TFloat, span);
			case StringLiteral(value, span): new TypedExpression(TStringLiteral(value), TString, span);
			case Variable(name, span):
				var type = scope.resolve(name);
				if (type != null) new TypedExpression(TLocal(name), type, span); else {
					var dot = name.indexOf(".");
					if (dot <= 0)
						fail("E1005", 'Unknown variable "$name"', span);
					var objectName = name.substr(0, dot),
						fieldName = name.substr(dot + 1),
						object = typeExpression(Variable(objectName, span), scope),
						field = fieldType(object.type, fieldName, span);
					new TypedExpression(TField(object, fieldName), field, span);
				}
			case Add(left, right, span): arithmetic(left, right, scope, true, span);
			case Sub(left, right, span): arithmetic(left, right, scope, false, span);
			case Mul(left, right, span): numeric(left, right, scope, 2, span);
			case Div(left, right, span): numeric(left, right, scope, 3, span);
			case Less(left, right, span): comparison(left, right, scope, 0, span);
			case LessEqual(left, right, span): comparison(left, right, scope, 1, span);
			case Equal(left, right, span): comparison(left, right, scope, 2, span);
			case New(typeName, arguments, span):
				if (!classDecls.exists(typeName))
					fail("E1007", 'Unknown class "$typeName"', span);
				var constructor = signatures.get(typeName + ".new"),
					expected = constructor == null ? [] : [for (argument in constructor.arguments) lowerType(argument.type)];
				if (arguments.length != expected.length)
					fail("E1008", 'Constructor "$typeName" expects ${expected.length} arguments, got ${arguments.length}', span);
				var typed = [for (argument in arguments) typeExpression(argument, scope)];
				checkArguments(typed, expected, typeName + ".new");
				new TypedExpression(TNew(typeName, typed, constructor != null), TClass(typeName), span);
			case Call(name, arguments, span):
				var dot = name.indexOf("."),
					receiverName = dot < 0 ? null : name.substr(0, dot),
					receiverType = receiverName == null ? null : scope.resolve(receiverName),
					methodName = dot < 0 ? null : name.substr(dot + 1);
				if (receiverType != null && methodName != null) {
					var className = switch receiverType {
						case TClass(value): value;
						default: null;
					};
					if (className == null)
						fail("E1007", 'Cannot call method on non-object "$receiverName"', span);
					var methodInfoResult = findMethod(className, methodName);
					if (methodInfoResult == null || methodInfoResult.isStatic)
						fail("E1007", 'Unknown instance method "$className.$methodName"', span);
					var methodKey = methodInfoResult.owner + "." + methodName;
					var method = signatures.get(methodKey),
						expected = [for (argument in method.arguments) lowerType(argument.type)],
						typed = [for (argument in arguments) typeExpression(argument, scope)];
					if (typed.length != expected.length)
						fail("E1008", 'Function "$methodKey" expects ${expected.length} arguments, got ${typed.length}', span);
					checkArguments(typed, expected, methodKey);
					new TypedExpression(TMethodCall(typeExpression(Variable(receiverName, span), scope), methodKey, typed), lowerType(method.result), span);
				} else {
					var signature = signatures.get(name);
					var external = externals.get(name),
						expectedArguments = signature == null ? (external == null ? null : external.arguments) : [for (argument in signature.arguments) lowerType(argument.type)],
						result = signature == null ? (external == null ? null : external.result) : lowerType(signature.result);
					if (expectedArguments == null)
						fail("E1007", 'Unknown function "$name"', span);
					if (arguments.length != expectedArguments.length)
						fail("E1008", 'Function "$name" expects ${expectedArguments.length} arguments, got ${arguments.length}', span);
					var typed = [for (argument in arguments) typeExpression(argument, scope)];
					checkArguments(typed, expectedArguments, name);
					new TypedExpression(TCall(name, typed), result, span);
				}
		}

	function checkArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, name:String):Void {
		for (i in 0...arguments.length)
			if (!sameType(arguments[i].type, expected[i]))
				fail("E1009", 'Argument ${i + 1} to "$name" has the wrong type', arguments[i].span);
	}

	function findMethod(className:String, name:String):Null<{owner:String, isStatic:Bool, isConstructor:Bool}> {
		var info = methodInfo.get(className + "." + name);
		if (info != null)
			return info;
		var classDecl = classDecls.get(className);
		return classDecl != null && classDecl.base != null ? findMethod(classDecl.base, name) : null;
	}

	function fieldType(type:CompilerType, name:String, span:SourceSpan):CompilerType {
		switch type {
			case TClass(className):
				var classDecl = classDecls.get(className);
				if (classDecl != null) {
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							return lowerType(field.type);
					if (classDecl.base != null)
						return fieldType(TClass(classDecl.base), name, span);
				}
				fail("E1005", 'Unknown field "$className.$name"', span);
			default:
				fail("E1005", 'Field "$name" requires an object', span);
		}
		return TVoid;
	}

	function arithmetic(a, b, scope, add, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!sameType(left.type, right.type) || (!sameType(left.type, TInt) && !sameType(left.type, TFloat)))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		return new TypedExpression(add ? TAdd(left, right) : TSub(left, right), left.type, span);
	}

	function numeric(a, b, scope, operation, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!sameType(left.type, right.type) || (!sameType(left.type, TInt) && !sameType(left.type, TFloat)))
			fail("E1010", "Arithmetic requires matching Int or Float operands", span);
		return new TypedExpression(operation == 2 ? TMul(left, right) : TDiv(left, right), left.type, span);
	}

	function comparison(a, b, scope, operation, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (!sameType(left.type, TInt) || !sameType(right.type, TInt))
			fail("E1011", "Comparison requires Int operands", span);
		return new TypedExpression(switch operation {
			case 0: TLess(left, right);
			case 1: TLessEqual(left, right);
			default: TEqual(left, right);
		}, TBool, span);
	}

	static function alwaysReturns(statements:Array<TypedStatement>):Bool {
		for (statement in statements)
			switch statement {
				case TReturn(_, _):
					return true;
				case TIf(_, yes, no, _):
					if (no.length > 0 && alwaysReturns(yes) && alwaysReturns(no))
						return true;
				default:
			}
		return false;
	}

	function lowerType(type:AstType):CompilerType
		return switch type {
			case IntType: TInt;
			case BoolType: TBool;
			case FloatType: TFloat;
			case StringType: TString;
			case VoidType: TVoid;
			case NamedType(name): TClass(name);
		};

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case VarDeclaration(_, _, _, span), Assignment(_, _, span), Return(_, span), If(_, _, _, span), While(_, _, span), Expression(_, span): span;
		}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return switch [left, right] {
			case [TClass(a), TClass(b)]: a == b;
			default: left == right;
		};
}
