package compiler.types;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.Ast.AstClass;
import compiler.Ast.AstInterface;
import compiler.Ast.AstEnum;
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
	var interfaceDecls:Map<String, AstInterface> = [];
	var aliases:Map<String, AstType> = [];
	var enumDecls:Map<String, AstEnum> = [];
	final generated:Array<TypedFunction> = [];
	final generatedClasses:Array<TypedClass> = [];
	var currentFunctionName:String = "";
	var loopDepth:Int = 0;

	public static function type(program:AstProgram):TypedProgram
		return new Typer(null).typeProgram(program, null);

	public static function typeSelected(program:AstProgram, selected:Map<String, Bool>,
			?externals:Map<String, {arguments:Array<CompilerType>, result:CompilerType}>):TypedProgram
		return new Typer(externals).typeProgram(program, selected);

	function new(externals)
		this.externals = externals == null ? [] : externals;

	function typeProgram(program:AstProgram, selected:Null<Map<String, Bool>>):TypedProgram {
		for (alias in program.aliases) {
			if (aliases.exists(alias.name) || classDecls.exists(alias.name) || interfaceDecls.exists(alias.name))
				fail("E1000", 'Duplicate type name "${alias.name}"', alias.span);
			aliases.set(alias.name, alias.type);
		}
		for (enumDecl in program.enums) {
			if (enumDecls.exists(enumDecl.name) || aliases.exists(enumDecl.name))
				fail("E1000", 'Duplicate type name "${enumDecl.name}"', enumDecl.span);
			enumDecls.set(enumDecl.name, enumDecl);
		}
		var classes:Map<String, AstClass> = [];
		for (interfaceDecl in program.interfaces) {
			if (interfaceDecls.exists(interfaceDecl.name))
				fail("E1000", 'Duplicate interface "${interfaceDecl.name}"', interfaceDecl.span);
			interfaceDecls.set(interfaceDecl.name, interfaceDecl);
			for (method in interfaceDecl.methods) {
				var qualified = interfaceDecl.name + "." + method.name;
				if (signatures.exists(qualified))
					fail("E1000", 'Duplicate interface method "$qualified"', method.span);
				signatures.set(qualified, method);
				methodInfo.set(qualified, {owner: interfaceDecl.name, isStatic: false, isConstructor: false});
			}
		}
		for (classDecl in program.classes) {
			if (classes.exists(classDecl.name))
				fail("E1000", 'Duplicate class "${classDecl.name}"', classDecl.span);
			if (interfaceDecls.exists(classDecl.name))
				fail("E1000", 'Class and interface share the name "${classDecl.name}"', classDecl.span);
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
		var typedInterfaces = [
			for (interfaceDecl in program.interfaces)
				{
					name: interfaceDecl.name,
					bases: interfaceDecl.bases,
					methods: [
						for (method in interfaceDecl.methods)
							{name: method.name, arguments: [for (argument in method.arguments) lowerType(argument.type)], result: lowerType(method.result)}
					]
				}
		], typedClasses = [for (classDecl in program.classes) typeClass(classDecl, classes)], typedFunctions:Array<TypedFunction> = [];
		for (fn in program.functions)
			if (selected == null || selected.exists(fn.name))
				typedFunctions.push(typeFunction(fn));
		for (classDecl in typedClasses)
			for (method in classDecl.methods)
				if (selected == null || selected.exists(method.name))
					typedFunctions.push(method);
		for (lambda in generated)
			typedFunctions.push(lambda);
		return {
			interfaces: typedInterfaces,
			classes: typedClasses.concat(generatedClasses),
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
		for (interfaceName in classDecl.interfaces) {
			if (!interfaceDecls.exists(interfaceName))
				fail("E1007", 'Unknown interface "$interfaceName"', classDecl.span);
			validateInterfaceImplementation(classDecl, interfaceName, classDecl.span);
		}
		return {
			name: classDecl.name,
			base: classDecl.base,
			interfaces: classDecl.interfaces,
			fields: fields,
			methods: [
				for (method in classDecl.methods)
					typeFunction(method, classDecl.name, method.isStatic)
			],
			span: classDecl.span
		};
	}

	function validateInterfaceImplementation(classDecl:AstClass, interfaceName:String, span:SourceSpan):Void {
		var interfaceDecl = interfaceDecls.get(interfaceName);
		if (interfaceDecl == null)
			return;
		for (base in interfaceDecl.bases) {
			if (!interfaceDecls.exists(base))
				fail("E1007", 'Unknown interface "$base"', span);
			validateInterfaceImplementation(classDecl, base, span);
		}
		for (method in interfaceDecl.methods) {
			var implementation = findMethod(classDecl.name, method.name);
			if (implementation == null || implementation.isStatic)
				fail("E1007", 'Class "${classDecl.name}" does not implement "$interfaceName.${method.name}"', span);
			var actual = signatures.get(implementation.owner + "." + method.name);
			if (actual == null || !sameSignature(actual, method))
				fail("E1003", 'Method "${classDecl.name}.${method.name}" does not match interface "$interfaceName"', span);
		}
	}

	static function sameSignature(left:AstFunction, right:AstFunction):Bool {
		if (left.arguments.length != right.arguments.length || Std.string(left.result) != Std.string(right.result))
			return false;
		for (i in 0...left.arguments.length)
			if (Std.string(left.arguments[i].type) != Std.string(right.arguments[i].type))
				return false;
		return true;
	}

	function typeFunction(fn:AstFunction, ?owner:String, isStatic:Bool = false):TypedFunction {
		var previousFunctionName = currentFunctionName;
		currentFunctionName = owner == null ? fn.name : owner + "." + fn.name;
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
		var resultFunction:TypedFunction = {
			name: owner == null ? fn.name : owner + "." + fn.name,
			owner: owner,
			isStatic: isStatic,
			isConstructor: isConstructor,
			arguments: arguments,
			result: result,
			statements: statements,
			span: fn.span
		};
		currentFunctionName = previousFunctionName;
		return resultFunction;
	}

	function typeStatements(statements:Array<AstStatement>, scope:Scope, result:CompilerType):Array<TypedStatement> {
		var output = [];
		for (statement in statements) {
			if (alwaysReturns(output))
				fail("E1012", "Unreachable statement", statementSpan(statement));
			switch statement {
				case VarDeclaration(name, declared, initializer, span):
					var value = typeExpression(initializer, scope);
					if (declared != null) {
						var expected = lowerType(declared);
						value = coerce(value, expected, 'local "$name"', "E1002");
					} else if (sameType(value.type, TNull)) {
						fail("E1002", 'Null requires an explicit nullable type for local "$name"', span);
					}
					scope.define(name, value.type, span);
					output.push(TVar(name, value, span));
				case Return(expression, span):
					var value = typeExpression(expression, scope);
					value = coerce(value, result, "return", "E1003");
					output.push(TReturn(value, span));
				case ReturnVoid(span):
					if (result != TVoid)
						fail("E1003", "Return type mismatch", span);
					output.push(TReturnVoid(span));
				case Break(span):
					if (loopDepth == 0)
						fail("E1017", "break is only valid inside a loop", span);
					output.push(TBreak(span));
				case Continue(span):
					if (loopDepth == 0)
						fail("E1017", "continue is only valid inside a loop", span);
					output.push(TContinue(span));
				case Assignment(name, expression, span):
					var dot = name.indexOf("."),
						value = typeExpression(expression, scope);
					if (dot < 0) {
						var expected = scope.resolve(name);
						if (expected == null)
							fail("E1005", 'Unknown variable "$name"', span);
						if (scope.isCapture(name))
							fail("E1013", 'Captured variable "$name" cannot be assigned in a lambda yet', span);
						value = coerce(value, expected, 'local "$name"', "E1002");
						output.push(TAssign(name, value, span));
					} else {
						var objectName = name.substr(0, dot),
							fieldName = name.substr(dot + 1),
							object = typeExpression(Variable(objectName, span), scope),
							expected = fieldType(object.type, fieldName, span);
						value = coerce(value, expected, 'field "$name"', "E1002");
						output.push(TFieldAssign(object, fieldName, value, span));
					}
				case IndexAssignment(array, offset, expression, span):
					var typedArray = typeExpression(array, scope),
						typedIndex = typeExpression(offset, scope),
						value = typeExpression(expression, scope);
					switch typedArray.type {
						case TMap(key, mapValue):
							typedIndex = coerce(typedIndex, key, "map key", "E1002");
							value = coerce(value, mapValue, "map value", "E1002");
							output.push(TMapAssign(typedArray, typedIndex, value, span));
						default:
							if (typedIndex.type != TInt)
								fail("E1014", "Array index must be Int", typedIndex.span);
							var element = arrayElementType(typedArray.type, span);
							if (!sameType(value.type, element))
								fail("E1002", "Array element assignment has the wrong type", span);
							output.push(TIndexAssign(typedArray, typedIndex, value, span));
					}
				case If(condition, thenBranch, elseBranch, span):
					var typedCondition = typeExpression(condition, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "If condition must be Bool", span);
					var thenScope = narrowedScope(scope, typedCondition, true),
						elseScope = narrowedScope(scope, typedCondition, false),
						typedThen = typeStatements(thenBranch, thenScope, result),
						typedElse = typeStatements(elseBranch, elseScope, result);
					output.push(TIf(typedCondition, typedThen, typedElse, span));
					if (elseBranch.length == 0 && alwaysReturns(typedThen))
						refineAfterGuard(scope, typedCondition);
				case While(condition, body, span):
					var typedCondition = typeExpression(condition, scope);
					if (!sameType(typedCondition.type, TBool))
						fail("E1004", "While condition must be Bool", span);
					loopDepth++;
					var typedBody = typeStatements(body, new Scope(scope), result);
					loopDepth--;
					output.push(TWhile(typedCondition, typedBody, span));
				case ForIn(name, iterable, body, span):
					var typedIterable = typeExpression(iterable, scope),
						element = arrayElementType(typedIterable.type, span),
						loopScope = new Scope(scope);
					loopScope.define(name, element, span);
					loopDepth++;
					var typedBody = typeStatements(body, loopScope, result);
					loopDepth--;
					output.push(TForIn(name, typedIterable, typedBody, span));
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
			case BoolLiteral(value, span): new TypedExpression(TBoolLiteral(value), TBool, span);
			case NullLiteral(span): new TypedExpression(TNullLiteral, TNull, span);
			case Variable(name, span):
				var type = scope.resolve(name);
				if (type != null) new TypedExpression(scope.isCapture(name) ? TCaptured(name) : TLocal(name), type, span); else {
					var signature = signatures.get(name);
					if (signature != null)
						new TypedExpression(TFunctionRef(name), functionType(signature), span);
					else {
						var dot = name.indexOf(".");
						if (dot <= 0) {
							var thisType = scope.resolve("this"),
								field = thisType == null ? null : findFieldType(thisType, name);
							if (field == null)
								fail("E1005", 'Unknown variable "$name"', span);
							new TypedExpression(TField(new TypedExpression(TLocal("this"), thisType, span), name), field, span);
						} else {
							var objectName = name.substr(0, dot),
								fieldName = name.substr(dot + 1),
								enumDecl = enumDecls.get(objectName);
							if (enumDecl != null) {
								var index = -1;
								for (i in 0...enumDecl.cases.length)
									if (enumDecl.cases[i].name == fieldName)
										index = i;
								if (index < 0)
									fail("E1005", 'Unknown enum case "$name"', span);
								return new TypedExpression(TEnumLiteral(objectName, index), TEnum(objectName), span);
							}
							var object = typeExpression(Variable(objectName, span), scope),
								field = fieldName == "length"
									&& isArray(object.type) ? arrayLengthType(object.type) : fieldName == "length"
									&& object.type == TString ? TInt : fieldType(object.type, fieldName, span);
							if (fieldName == "length" && isArray(object.type))
								new TypedExpression(TArrayLength(object), TInt, span)
							else if (fieldName == "length" && object.type == TString)
								new TypedExpression(TStringLength(object), TInt, span)
							else
								new TypedExpression(TField(object, fieldName), field, span);
						}
					}
				}
			case Lambda(arguments, body, span):
				var lambdaArguments = [
					for (argument in arguments)
						{name: argument.name, type: lowerType(argument.type)}
				], lambdaScope = new Scope(), declared:Map<String, Bool> = [];
				for (argument in lambdaArguments) {
					lambdaScope.define(argument.name, argument.type, span);
					declared.set(argument.name, true);
				}
				collectDeclaredLocals(body, declared);
				var freeVariables:Map<String, Bool> = [];
				collectVariables(body, freeVariables);
				var captures = [];
				for (name in freeVariables.keys())
					if (!declared.exists(name)) {
						var capturedType = scope.resolve(name);
						if (capturedType != null) {
							lambdaScope.defineCapture(name, capturedType, span);
							captures.push(name);
						}
					}
				var inferredResult:CompilerType = TVoid;
				for (statement in body)
					switch statement {
						case Return(value, _):
							var typedValue = typeExpression(value, lambdaScope);
							if (inferredResult == TVoid) inferredResult = typedValue.type; else if (!sameType(inferredResult,
								typedValue.type)) fail("E1003", "Lambda return types do not match", span);
						default:
					}
				var typedBodyScope = new Scope();
				for (argument in lambdaArguments)
					typedBodyScope.define(argument.name, argument.type, span);
				for (name in captures)
					typedBodyScope.defineCapture(name, scope.resolve(name), span);
				var lambdaName = '$' + 'lambda:' + currentFunctionName + ':' + span.start,
					typedBody = typeStatements(body, typedBodyScope, inferredResult);
				if (inferredResult != TVoid && !alwaysReturns(typedBody))
					fail("E1006", 'Function $lambdaName does not return on every path', span);
				var environment = captures.length == 0 ? null : '$' + 'lambda-env:' + currentFunctionName + ':' + span.start;
				if (environment != null)
					generatedClasses.push({
						name: environment,
						base: null,
						interfaces: [],
						fields: [
							for (name in captures)
								{
									name: name,
									type: scope.resolve(name),
									isStatic: false,
									isFinal: false,
									span: span
								}
						],
						methods: [],
						span: span
					});
				generated.push({
					name: lambdaName,
					owner: environment,
					isStatic: environment == null,
					isConstructor: false,
					arguments: lambdaArguments,
					result: inferredResult,
					statements: typedBody,
					span: span
				});
				new TypedExpression(TLambda(lambdaName, environment, captures), TFunction([for (argument in lambdaArguments) argument.type], inferredResult),
					span);
			case Member(object, name, span): typeMember(object, name, span, scope);
			case Add(left, right, span): arithmetic(left, right, scope, true, span);
			case Sub(left, right, span): arithmetic(left, right, scope, false, span);
			case Mul(left, right, span): numeric(left, right, scope, 2, span);
			case Div(left, right, span): numeric(left, right, scope, 3, span);
			case Less(left, right, span): comparison(left, right, scope, 0, span);
			case LessEqual(left, right, span): comparison(left, right, scope, 1, span);
			case Equal(left, right, span): comparison(left, right, scope, 2, span);
			case New(typeName, arguments, span):
				if (!classDecls.exists(typeName) || interfaceDecls.exists(typeName))
					fail("E1007", 'Unknown class "$typeName"', span);
				var constructor = signatures.get(typeName + ".new"),
					expected = constructor == null ? [] : [for (argument in constructor.arguments) lowerType(argument.type)];
				if (arguments.length != expected.length)
					fail("E1008", 'Constructor "$typeName" expects ${expected.length} arguments, got ${arguments.length}', span);
				var typed = [for (argument in arguments) typeExpression(argument, scope)];
				typed = coerceArguments(typed, expected, typeName + ".new");
				new TypedExpression(TNew(typeName, typed, constructor != null), TClass(typeName), span);
			case NewArray(element, length, span):
				var typedLength = typeExpression(length, scope);
				if (typedLength.type != TInt)
					fail("E1014", "Array length must be Int", typedLength.span);
				var loweredElement = lowerType(element);
				new TypedExpression(TNewArray(loweredElement, typedLength), TArray(loweredElement), span);
			case NewMap(key, value, span):
				var loweredKey = lowerType(key),
					loweredValue = lowerType(value);
				if (!sameType(loweredKey, TString) || !sameType(loweredValue, TInt))
					fail("E1016", "Only Map<String,Int> is supported by the compiler runtime", span);
				new TypedExpression(TNewMap(loweredKey, loweredValue), TMap(loweredKey, loweredValue), span);
			case Index(array, offset, span):
				var typedArray = typeExpression(array, scope),
					typedIndex = typeExpression(offset, scope);
				switch typedArray.type {
					case TMap(key, value):
						var typedKey = coerce(typedIndex, key, "map key", "E1002");
						new TypedExpression(TMapGet(typedArray, typedKey), value, span);
					default:
						if (typedIndex.type != TInt)
							fail("E1014", "Array index must be Int", typedIndex.span);
						var element = arrayElementType(typedArray.type, span);
						new TypedExpression(TIndex(typedArray, typedIndex), element, span);
				}
			case Call(name, arguments, span):
				var callable = scope.resolve(name);
				if (callable != null) {
					var functionType = switch callable {
						case TFunction(argumentTypes, result): {arguments: argumentTypes, result: result};
						default: null;
					};
					if (functionType == null)
						fail("E1007", 'Cannot call non-function "$name"', span);
					var typed = [for (argument in arguments) typeExpression(argument, scope)];
					if (typed.length != functionType.arguments.length)
						fail("E1008", 'Function value "$name" expects ${functionType.arguments.length} arguments, got ${typed.length}', span);
					typed = coerceArguments(typed, functionType.arguments, name);
					new TypedExpression(TClosureCall(new TypedExpression(TLocal(name), callable, span), typed), functionType.result, span);
				} else {
					var dot = name.indexOf("."),
						receiverName = dot < 0 ? null : name.substr(0, dot),
						receiver = receiverName == null ? null : resolveReceiver(receiverName, span, scope),
						receiverType = receiver == null ? null : receiver.type,
						methodName = dot < 0 ? null : name.substr(dot + 1);
					if (receiverType != null && methodName != null) {
						if (receiverType == TString && methodName == "indexOf") {
							if (arguments.length != 1)
								fail("E1008", 'Function "String.indexOf" expects 1 argument, got ${arguments.length}', span);
							var needle = typeExpression(arguments[0], scope);
							if (!sameType(needle.type, TString))
								fail("E1009", "String.indexOf expects a String needle", needle.span);
							return new TypedExpression(TStringIndexOf(receiver, needle), TInt, span);
						}
						if (receiverType == TString && methodName == "substring") {
							if (arguments.length != 2)
								fail("E1008", 'Function "String.substring" expects 2 arguments, got ${arguments.length}', span);
							var start = typeExpression(arguments[0], scope),
								end = typeExpression(arguments[1], scope);
							if (!sameType(start.type, TInt) || !sameType(end.type, TInt))
								fail("E1009", "String.substring expects Int bounds", span);
							return new TypedExpression(TStringSubstring(receiver, start, end), TString, span);
						}
						if (isMap(receiverType))
							return typeMapMethod(receiver, methodName, arguments, span, scope);
						var className = switch receiverType {
							case TClass(value), TInterface(value): value;
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
						typed = coerceArguments(typed, expected, methodKey);
						new TypedExpression(TMethodCall(receiver, methodKey, typed), lowerType(method.result), span);
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
						typed = coerceArguments(typed, expectedArguments, name);
						new TypedExpression(TCall(name, typed), result, span);
					}
				}
			case MethodCall(object, name, arguments, span): typeMethodCall(object, name, arguments, span, scope);
		}

	function typeMember(object:AstExpression, name:String, span:SourceSpan, scope:Scope):TypedExpression {
		var typedObject = typeExpression(object, scope);
		if (name == "length" && isArray(typedObject.type))
			return new TypedExpression(TArrayLength(typedObject), TInt, span);
		if (name == "length" && sameType(typedObject.type, TString))
			return new TypedExpression(TStringLength(typedObject), TInt, span);
		return new TypedExpression(TField(typedObject, name), fieldType(typedObject.type, name, span), span);
	}

	function typeMethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var receiver = typeExpression(object, scope);
		if (sameType(receiver.type, TString) && name == "indexOf") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.indexOf" expects 1 argument, got ${arguments.length}', span);
			var needle = typeExpression(arguments[0], scope);
			if (!sameType(needle.type, TString))
				fail("E1009", "String.indexOf expects a String needle", needle.span);
			return new TypedExpression(TStringIndexOf(receiver, needle), TInt, span);
		}
		if (sameType(receiver.type, TString) && name == "substring") {
			if (arguments.length != 2)
				fail("E1008", 'Function "String.substring" expects 2 arguments, got ${arguments.length}', span);
			var start = typeExpression(arguments[0], scope),
				end = typeExpression(arguments[1], scope);
			if (!sameType(start.type, TInt) || !sameType(end.type, TInt))
				fail("E1009", "String.substring expects Int bounds", span);
			return new TypedExpression(TStringSubstring(receiver, start, end), TString, span);
		}
		if (isMap(receiver.type))
			return typeMapMethod(receiver, name, arguments, span, scope);
		var className = switch receiver.type {
			case TClass(value), TInterface(value): value;
			default: null;
		};
		if (className == null)
			fail("E1007", 'Cannot call method on non-object "$name"', span);
		var methodInfoResult = findMethod(className, name);
		if (methodInfoResult == null || methodInfoResult.isStatic)
			fail("E1007", 'Unknown instance method "$className.$name"', span);
		var methodKey = methodInfoResult.owner + "." + name,
			method = signatures.get(methodKey),
			expected = [for (argument in method.arguments) lowerType(argument.type)],
			typed = [for (argument in arguments) typeExpression(argument, scope)];
		if (typed.length != expected.length)
			fail("E1008", 'Function "$methodKey" expects ${expected.length} arguments, got ${typed.length}', span);
		typed = coerceArguments(typed, expected, methodKey);
		return new TypedExpression(TMethodCall(receiver, methodKey, typed), lowerType(method.result), span);
	}

	function typeMapMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var mapType = switch receiver.type {
			case TMap(key, value): {key: key, value: value};
			default: throw "Not a map";
		};
		if (name == "set") {
			if (arguments.length != 2)
				fail("E1008", "Map.set expects a key and value", span);
			var key = coerce(typeExpression(arguments[0], scope), mapType.key, "map key", "E1002"),
				value = coerce(typeExpression(arguments[1], scope), mapType.value, "map value", "E1002");
			return new TypedExpression(TCall("__map_string_i32_set", [receiver, key, value]), TVoid, span);
		}
		if (arguments.length != 1)
			fail("E1008", 'Map.$name expects one argument', span);
		var key = coerce(typeExpression(arguments[0], scope), mapType.key, "map key", "E1002");
		return switch name {
			case "exists": new TypedExpression(TCall("__map_string_i32_exists", [receiver, key]), TBool, span);
			case "get": new TypedExpression(TMapGet(receiver, key), mapType.value, span);
			default:
				fail("E1007", 'Unknown map method "$name"', span);
				new TypedExpression(TNullLiteral, TVoid, span);
		};
	}

	function narrowedScope(scope:Scope, condition:TypedExpression, truthy:Bool):Scope {
		var result = new Scope(scope), comparison = nullComparison(condition);
		if (comparison != null)
			result.refine(comparison.name, truthy ? TNull : comparison.nonNullType);
		return result;
	}

	function refineAfterGuard(scope:Scope, condition:TypedExpression):Void {
		var comparison = nullComparison(condition);
		if (comparison != null)
			scope.refine(comparison.name, comparison.nonNullType);
	}

	function nullComparison(condition:TypedExpression):Null<{name:String, nonNullType:CompilerType}> {
		return switch condition.expression {
			case TEqual(left, right): var local = nullableLocal(left),
					other = isNullValue(right) ? true : false; if (local == null) {
					local = nullableLocal(right);
					other = isNullValue(left);
				} local == null || !other ? null : local;
			default: null;
		};
	}

	function nullableLocal(expression:TypedExpression):Null<{name:String, nonNullType:CompilerType}> {
		return switch expression.expression {
			case TLocal(name): switch expression.type {
					case TNullable(element): {name: name, nonNullType: element};
					default: null;
				};
			default: null;
		};
	}

	static function isNullValue(expression:TypedExpression):Bool
		return switch expression.expression {
			case TNullLiteral: true;
			case TNullableWrap(value): isNullValue(value);
			default: false;
		};

	function functionType(fn:AstFunction):CompilerType
		return TFunction([for (argument in fn.arguments) lowerType(argument.type)], lowerType(fn.result));

	static function collectDeclaredLocals(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case VarDeclaration(name, _, _, _):
					names.set(name, true);
				case If(_, yes, no, _):
					collectDeclaredLocals(yes, names);
					collectDeclaredLocals(no, names);
				case While(_, body, _):
					collectDeclaredLocals(body, names);
				case ForIn(name, _, body, _):
					names.set(name, true);
					collectDeclaredLocals(body, names);
				case Break(_), Continue(_):
				default:
			}
	}

	static function collectVariables(statements:Array<AstStatement>, names:Map<String, Bool>):Void {
		for (statement in statements)
			switch statement {
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Expression(expression, _):
					collectExpressionVariables(expression, names);
				case IndexAssignment(array, offset, expression, _):
					collectExpressionVariables(array, names);
					collectExpressionVariables(offset, names);
					collectExpressionVariables(expression, names);
				case ReturnVoid(_):
				case If(condition, yes, no, _):
					collectExpressionVariables(condition, names);
					collectVariables(yes, names);
					collectVariables(no, names);
				case While(condition, body, _):
					collectExpressionVariables(condition, names);
					collectVariables(body, names);
				case ForIn(_, iterable, body, _):
					collectExpressionVariables(iterable, names);
					collectVariables(body, names);
				case Break(_), Continue(_):
			}
	}

	static function collectExpressionVariables(expression:AstExpression, names:Map<String, Bool>):Void
		switch expression {
			case Variable(name, _):
				names.set(name, true);
			case Member(object, _, _):
				collectExpressionVariables(object, names);
			case MethodCall(object, _, arguments, _):
				collectExpressionVariables(object, names);
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case Call(_, arguments, _):
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Less(left, right, _), LessEqual(left, right, _),
				Equal(left, right, _):
				collectExpressionVariables(left, names);
				collectExpressionVariables(right, names);
			case New(_, arguments, _):
				for (argument in arguments)
					collectExpressionVariables(argument, names);
			case NewArray(_, length, _):
				collectExpressionVariables(length, names);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				collectExpressionVariables(array, names);
				collectExpressionVariables(offset, names);
			case Lambda(_, _, _):
				return;
			case IntegerLiteral(_, _):
				return;
			case FloatLiteral(_, _):
				return;
			case StringLiteral(_, _):
				return;
			case BoolLiteral(_, _), NullLiteral(_):
				return;
		}

	function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, name:String):Array<TypedExpression> {
		var output = [];
		for (i in 0...arguments.length)
			output.push(coerce(arguments[i], expected[i], 'argument ${i + 1} to "$name"'));
		return output;
	}

	function coerce(value:TypedExpression, expected:CompilerType, context:String, code:String = "E1009"):TypedExpression {
		if (sameType(value.type, expected))
			return value;
		if (isAssignable(value.type, expected))
			return switch [value.type, expected] {
				case [TClass(_), TInterface(name)], [TInterface(_), TInterface(name)]:
					new TypedExpression(TToInterface(value, name), expected, value.span);
				case [_, TNullable(_)]:
					new TypedExpression(TNullableWrap(value), expected, value.span);
				default: value;
			};
		fail(code, 'Type mismatch for $context', value.span);
		return value;
	}

	function isAssignable(actual:CompilerType, expected:CompilerType):Bool {
		if (sameType(actual, expected))
			return true;
		return switch [actual, expected] {
			case [TClass(actualName), TClass(expectedName)]: classImplements(actualName, expectedName);
			case [TClass(actualName), TInterface(expectedName)]: classImplements(actualName, expectedName);
			case [TInterface(actualName), TInterface(expectedName)]: interfaceExtends(actualName, expectedName);
			case [TNull, TNullable(_)]: true;
			case [actual, TNullable(expected)]: isReference(actual) && (sameType(actual, expected) || isAssignable(actual, expected));
			case [TArray(actualElement), TArray(expectedElement)]: sameType(actualElement, expectedElement);
			default: false;
		};
	}

	function classImplements(actualName:String, expectedName:String):Bool {
		var actualClass = classDecls.get(actualName);
		if (actualClass == null)
			return interfaceExtends(actualName, expectedName);
		if (actualClass.base != null && classImplements(actualClass.base, expectedName))
			return true;
		for (interfaceName in actualClass.interfaces)
			if (interfaceName == expectedName || interfaceExtends(interfaceName, expectedName))
				return true;
		return false;
	}

	function interfaceExtends(actualName:String, expectedName:String):Bool {
		var actualInterface = interfaceDecls.get(actualName);
		if (actualInterface == null)
			return false;
		for (base in actualInterface.bases)
			if (base == expectedName || interfaceExtends(base, expectedName))
				return true;
		return false;
	}

	function findMethod(className:String, name:String):Null<{owner:String, isStatic:Bool, isConstructor:Bool}> {
		var info = methodInfo.get(className + "." + name);
		if (info != null)
			return info;
		var classDecl = classDecls.get(className);
		if (classDecl != null)
			return classDecl.base == null ? null : findMethod(classDecl.base, name);
		var interfaceDecl = interfaceDecls.get(className);
		if (interfaceDecl != null)
			for (base in interfaceDecl.bases) {
				var inherited = findMethod(base, name);
				if (inherited != null)
					return inherited;
			}
		return null;
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

	function resolveReceiver(name:String, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		if (scope.resolve(name) != null)
			return typeExpression(Variable(name, span), scope);
		var thisType = scope.resolve("this");
		if (thisType != null && findFieldType(thisType, name) != null)
			return typeExpression(Variable(name, span), scope);
		return null;
	}

	function findFieldType(type:CompilerType, name:String):Null<CompilerType>
		return switch type {
			case TClass(className):
				var classDecl = classDecls.get(className),
					found:Null<CompilerType> = null;
				if (classDecl != null) {
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							found = lowerType(field.type);
					if (found == null && classDecl.base != null)
						found = findFieldType(TClass(classDecl.base), name);
				}
				found;
			default: null;
		};

	function arithmetic(a, b, scope, add, span):TypedExpression {
		var left = typeExpression(a, scope), right = typeExpression(b, scope);
		if (add && sameType(left.type, TString) && sameType(right.type, TString))
			return new TypedExpression(TAdd(left, right), TString, span);
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
		if (operation == 2) {
			if (sameType(left.type, TNull) && isNullable(right.type))
				left = coerce(left, right.type, "null comparison");
			else if (sameType(right.type, TNull) && isNullable(left.type))
				right = coerce(right, left.type, "null comparison");
		}
		if (operation == 2 && sameType(left.type, TString) && sameType(right.type, TString))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && sameType(left.type, TBool) && sameType(right.type, TBool))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && (sameType(left.type, TNull) || sameType(right.type, TNull)))
			switch [left.type, right.type] {
				case [TNull, TNullable(_)], [TNullable(_), TNull], [TNullable(_), TNullable(_)]:
					return new TypedExpression(TEqual(left, right), TBool, span);
				default:
			}
		if (operation == 2 && sameType(left.type, right.type))
			switch left.type {
				case TEnum(_), TNullable(_):
					return new TypedExpression(TEqual(left, right), TBool, span);
				default:
			}
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
				case TReturn(_, _), TReturnVoid(_):
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
			case NamedType(name):
				var alias = aliases.get(name);
				alias == null ? (interfaceDecls.exists(name) ? TInterface(name) : enumDecls.exists(name) ? TEnum(name) : TClass(name)) : lowerType(alias);
			case ArrayType(element): TArray(lowerType(element));
			case MapType(key, value): TMap(lowerType(key), lowerType(value));
			case NullableType(element): TNullable(lowerType(element));
			case FunctionType(arguments, result): TFunction([for (argument in arguments) lowerType(argument)], lowerType(result));
		};

	function arrayElementType(type:CompilerType, span:SourceSpan):CompilerType
		return switch type {
			case TArray(element): element;
			default:
				fail("E1015", "Indexing requires an Array value", span);
				TVoid;
		};

	function arrayLengthType(type:CompilerType):CompilerType
		return isArray(type) ? TInt : TVoid;

	static function isArray(type:CompilerType):Bool
		return switch type {
			case TArray(_): true;
			default: false;
		};

	static function isMap(type:CompilerType):Bool
		return switch type {
			case TMap(_, _): true;
			default: false;
		};

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	static function isReference(type:CompilerType):Bool
		return switch type {
			case TString, TClass(_), TInterface(_), TArray(_), TFunction(_), TMap(_, _): true;
			default: false;
		};

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), If(_, _, _, span),
				While(_, _, span), ForIn(_, _, _, span), Break(span), Continue(span), Expression(_, span): span;
		}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return switch [left, right] {
			case [TClass(a), TClass(b)]: a == b;
			case [TInterface(a), TInterface(b)]: a == b;
			case [TEnum(a), TEnum(b)]: a == b;
			case [TNullable(a), TNullable(b)]: sameType(a, b);
			case [TMap(aKey, aValue), TMap(bKey, bValue)]: sameType(aKey, bKey) && sameType(aValue, bValue);
			case [TArray(a), TArray(b)]: sameType(a, b);
			case [TFunction(aArgs, aResult), TFunction(bArgs, bResult)]: aArgs.length == bArgs.length && [
					for (i in 0...aArgs.length)
						sameType(aArgs[i], bArgs[i])
				].indexOf(false) < 0 && sameType(aResult, bResult);
			default: left == right;
		};
}
