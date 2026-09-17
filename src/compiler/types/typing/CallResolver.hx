package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.NativeLayout;
import compiler.runtime.PlatformAbi;
import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstEnumParameter;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstTypeConstraint;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.analysis.Scope;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.AbstractConstructorNormalizer;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypeRelations;
import compiler.semantic.SemanticSignature;

typedef TypeExpressionCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef CoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;
typedef ArgumentTypeCallback = (AstArgument, Null<Map<String, CompilerType>>) -> CompilerType;
typedef DefaultExpressionCallback = (AstExpression, CompilerType, String) -> TypedExpression;
typedef InferTypeParametersCallback = (AstType, CompilerType, Array<String>, Map<String, CompilerType>, SourceSpan) -> Void;
typedef FindCallableFieldTypeCallback = (CompilerType, String) -> Null<CompilerType>;
typedef TypeCallableFieldCallback = (TypedExpression, String, SourceSpan) -> TypedExpression;
typedef LowerCallTypeCallback = AstType->CompilerType;
typedef CallArrayElementTypeCallback = (CompilerType, SourceSpan) -> CompilerType;
typedef ResolveCallReceiverCallback = (String, SourceSpan, Scope) -> Null<TypedExpression>;
typedef TypeCallMemberWithFlowCallback = (TypedExpression, String, SourceSpan, Scope) -> TypedExpression;

typedef EnumConstructorInfo = {
	enumName:String,
	index:Int,
	params:Array<AstEnumParameter>,
	typeParameters:Array<String>
};

/** Resolves callable lookup, dispatch, construction, and source arguments. */
class CallResolver {
	final session:TypingSession;
	final genericInstantiation:GenericInstantiation;
	final typeExpression:TypeExpressionCallback;
	final coerce:CoerceCallback;
	final argumentType:ArgumentTypeCallback;
	final posInfosExpression:SourceSpan->AstExpression;
	final typeDefaultExpression:DefaultExpressionCallback;
	final functionTypeParameters:AstFunction->Array<String>;
	final inferTypeParameters:InferTypeParametersCallback;
	final inheritanceName:AstType->String;
	final findCallableFieldType:FindCallableFieldTypeCallback;
	final typeCallableField:TypeCallableFieldCallback;
	final lowerType:LowerCallTypeCallback;
	final arrayElementType:CallArrayElementTypeCallback;
	final resolveCallReceiver:ResolveCallReceiverCallback;
	final typeCallMemberWithFlow:TypeCallMemberWithFlowCallback;

	public function new(session:TypingSession, genericInstantiation:GenericInstantiation, typeExpression:TypeExpressionCallback, coerce:CoerceCallback,
			argumentType:ArgumentTypeCallback, posInfosExpression:SourceSpan->AstExpression, typeDefaultExpression:DefaultExpressionCallback,
			functionTypeParameters:AstFunction->Array<String>, inferTypeParameters:InferTypeParametersCallback, inheritanceName:AstType->String,
			findCallableFieldType:FindCallableFieldTypeCallback, typeCallableField:TypeCallableFieldCallback, lowerType:LowerCallTypeCallback,
			arrayElementType:CallArrayElementTypeCallback, resolveCallReceiver:ResolveCallReceiverCallback,
			typeCallMemberWithFlow:TypeCallMemberWithFlowCallback) {
		this.session = session;
		this.genericInstantiation = genericInstantiation;
		this.typeExpression = typeExpression;
		this.coerce = coerce;
		this.argumentType = argumentType;
		this.posInfosExpression = posInfosExpression;
		this.typeDefaultExpression = typeDefaultExpression;
		this.functionTypeParameters = functionTypeParameters;
		this.inferTypeParameters = inferTypeParameters;
		this.inheritanceName = inheritanceName;
		this.findCallableFieldType = findCallableFieldType;
		this.typeCallableField = typeCallableField;
		this.lowerType = lowerType;
		this.arrayElementType = arrayElementType;
		this.resolveCallReceiver = resolveCallReceiver;
		this.typeCallMemberWithFlow = typeCallMemberWithFlow;
	}

	public function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>, name:String):Array<TypedExpression> {
		var output:Array<TypedExpression> = [];
		for (i in 0...arguments.length)
			output.push(coerce(arguments[i], expected[i], 'argument ${i + 1} to "$name"', "E1009"));
		return output;
	}

	public function typeCallArguments(arguments:Array<AstExpression>, expected:Array<CompilerType>, scope:Scope, name:String):Array<TypedExpression> {
		var typed = [
			for (i in 0...arguments.length)
				typeExpression(arguments[i], scope, expected[i], false)
		];
		return coerceArguments(typed, expected, name);
	}

	public function typeMethodCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, platformFirst:Bool = true, receiverName:Null<String> = null,
			contextualGenericArguments:Bool = true):TypedExpression {
		if (isRawPointerType(receiver.type)) {
			var rawPointerCall = typeRawPointerMethod(receiver, name, arguments, span, scope, expectedType);
			if (rawPointerCall != null)
				return rawPointerCall;
		}
		var platformMethod = PlatformAbi.method(receiver.type, name);
		if (platformFirst && platformMethod != null) {
			var typed = typeCallArguments(arguments, platformMethod.arguments, scope, name);
			return new TypedExpression(TCall(platformMethod.nativeName, [receiver].concat(typed)), platformMethod.result, span);
		}
		var stringCall = typeStringMethod(receiver, name, arguments, span, scope);
		if (stringCall != null)
			return stringCall;
		if (isMap(receiver.type))
			return typeMapMethod(receiver, name, arguments, span, scope);
		if (isArray(receiver.type))
			return typeArrayMethod(receiver, name, arguments, span, scope);
		if (isIterator(receiver.type))
			return typeIteratorMethod(receiver, name, arguments, span);
		if (!platformFirst && platformMethod != null) {
			var typed = typeCallArguments(arguments, platformMethod.arguments, scope, name);
			return new TypedExpression(TCall(platformMethod.nativeName, [receiver].concat(typed)), platformMethod.result, span);
		}
		var abstractCall = typeAbstractMethodCall(receiver, name, arguments, span, scope);
		if (abstractCall != null)
			return abstractCall;
		var fieldCall = typeFunctionFieldCall(receiver, name, arguments, span, scope);
		if (fieldCall != null)
			return fieldCall;
		return resolveInstanceMethod(receiver, name, arguments, span, scope, expectedType, receiverName, contextualGenericArguments);
	}

	public function typeRawPointerNullCall(name:String, arguments:Array<AstExpression>, span:SourceSpan,
			expectedType:Null<CompilerType>):Null<TypedExpression> {
		if (name != "RawPtr.nullPtr" && !StringTools.endsWith(name, ".RawPtr.nullPtr"))
			return null;
		if (arguments.length != 0)
			fail("E1008", 'RawPtr.nullPtr expects no arguments, got ${arguments.length}', span);
		return switch expectedType {
			case TAbstract(declaration, typeArguments, _) if (isRawPointerAbstract(declaration) && typeArguments.length == 1):
				new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), expectedType, span);
			case _:
				fail("E1009", "RawPtr.nullPtr needs an expected RawPtr<T> type", span);
				null;
		};
	}

	function typeRawPointerMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):Null<TypedExpression> {
		var typeArguments = switch receiver.type {
			case TAbstract(declaration, arguments, _) if (isRawPointerAbstract(declaration)): arguments;
			case _: return null;
		};
		if (typeArguments.length != 1)
			fail("E1022", "RawPtr<T> requires exactly one pointee type", span);
		var pointee = typeArguments[0];
		switch name {
			case "isNull":
				if (arguments.length != 0)
					fail("E1008", "RawPtr.isNull expects no arguments", span);
				return new TypedExpression(TCall("$rawptr.isNull", [receiver]), TBool, span);
			case "load":
				if (arguments.length != 0)
					fail("E1008", "RawPtr.load expects no arguments", span);
				if (NativeLayout.isNativeValue(pointee))
					fail("E1022", "Native records are address-only and cannot be loaded by value", span);
				var layout = nativeMemoryLayout(pointee, span);
				return new TypedExpression(TCall("$rawptr.load", [
					receiver,
					new TypedExpression(TIntLiteral(layout.size), TInt, span),
					new TypedExpression(TBoolLiteral(layout.signed), TBool, span)
				]), pointee, span);
			case "store":
				if (arguments.length != 1)
					fail("E1008", "RawPtr.store expects one value", span);
				if (NativeLayout.isNativeValue(pointee))
					fail("E1022", "Native records are address-only and cannot be stored by value", span);
				var layout = nativeMemoryLayout(pointee, span),
					value = coerce(typeExpression(arguments[0], scope, pointee, false), pointee, "RawPtr.store value", "E1002");
				return new TypedExpression(TCall("$rawptr.store", [receiver, value, new TypedExpression(TIntLiteral(layout.size), TInt, span)]), TVoid, span);
			case "offset":
				if (arguments.length != 1)
					fail("E1008", "RawPtr.offset expects one element count", span);
				var layout = nativeMemoryLayout(pointee, span),
					count = coerce(typeExpression(arguments[0], scope, TInt, false), TInt, "RawPtr.offset count", "E1002");
				return new TypedExpression(TCall("$rawptr.offset", [receiver, count, new TypedExpression(TIntLiteral(layout.size), TInt, span)]),
					receiver.type, span);
			case "byteOffset":
				if (arguments.length != 1)
					fail("E1008", "RawPtr.byteOffset expects one byte count", span);
				var count = coerce(typeExpression(arguments[0], scope, TInt, false), TInt, "RawPtr.byteOffset count", "E1002");
				return new TypedExpression(TCall("$rawptr.byteOffset", [receiver, count]), receiver.type, span);
			case "castTo":
				if (arguments.length != 0)
					fail("E1008", "RawPtr.castTo expects no arguments", span);
				return switch expectedType {
					case TAbstract(declaration, castArguments, _) if (isRawPointerAbstract(declaration) && castArguments.length == 1):
						session.representation.boundaryCast(receiver, expectedType);
					case _:
						fail("E1009", "RawPtr.castTo needs an expected RawPtr<U> type", span);
						null;
				};
			case _:
				return null;
		}
		return null;
	}

	function nativeMemoryLayout(type:CompilerType, span:SourceSpan):{size:Int, signed:Bool} {
		if (NativeLayout.isNativeValue(type)) {
			var name = switch type {
				case TInstance(NominalKind.NativeValue, name, _): name;
				case _: throw "Native value type check lost its nominal type";
			};
			var layout = session.nativeLayoutsByName.get(name);
			if (layout == null)
				fail("E1022", 'Native value "$name" has no layout for ABI target "${session.nativeAbiTarget}"', span);
			return {size: layout.size, signed: false};
		}
		var hxiType = try NativeLayout.fieldType(type) catch (_:Dynamic) {
			fail("E1022", 'Type "$type" has no fixed native memory layout', span);
			cast null;
		}, abi = HxiAbi.forTarget(session.nativeAbiTarget), layout = abi.layout(hxiType);
		if (layout == null)
			fail("E1022", 'Type "$type" has no fixed native memory layout for "${session.nativeAbiTarget}"', span);
		var signed = switch abi.classify(hxiType) {
			case IntegerValue(_, HxiIntegerSign.Signed) | EnumerationValue(_, _, HxiIntegerSign.Signed): true;
			case _: false;
		};
		return {size: layout.size, signed: signed};
	}

	static function isRawPointerType(type:CompilerType):Bool
		return switch type {
			case TAbstract(name, _, _) if (isRawPointerAbstract(name)): true;
			case _: false;
		};

	static function isRawPointerAbstract(declaration:String):Bool
		return declaration == "RawPtr" || StringTools.endsWith(declaration, ".RawPtr");

	function typeExpressionValue(expression:AstExpression, scope:Scope, ?expectedType:CompilerType):TypedExpression
		return typeExpression(expression, scope, expectedType, false);

	public function typeDeclaredCallArguments(arguments:Array<AstExpression>, parameters:Array<AstArgument>, scope:Scope, name:String, span:SourceSpan,
			?substitutions:Map<String, CompilerType>):Array<TypedExpression> {
		var required = parameters.length;
		while (required > 0 && parameters[required - 1].optional == true)
			required--;
		if (arguments.length < required || arguments.length > parameters.length) {
			var expected = required == parameters.length ? '$required' : '$required to ${parameters.length}';
			fail("E1008", 'Function "$name" expects $expected arguments, got ${arguments.length}', span);
		}
		var typed:Array<TypedExpression> = [];
		for (i in 0...arguments.length) {
			var supplied = argumentType(parameters[i], substitutions),
				value = typeExpression(arguments[i], scope, supplied, false);
			typed.push(coerce(value, supplied, 'argument ${i + 1} to "$name"', "E1009"));
		}
		for (i in arguments.length...parameters.length) {
			var parameter = parameters[i],
				expected = argumentType(parameter, substitutions),
				defaultValue = parameter.defaultValue;
			if (isPosInfosParameter(parameter))
				typed.push(coerce(typeExpression(posInfosExpression(span), scope, expected, false), expected, 'position argument ${i + 1} to "$name"',
					"E1009"));
			else if (defaultValue == null)
				typed.push(coerce(new TypedExpression(TNullLiteral, TNull, span), expected, 'default argument ${i + 1} to "$name"', "E1009"));
			else
				typed.push(coerce(typeDefaultExpression(defaultValue, expected, name), expected, 'default argument ${i + 1} to "$name"', "E1009"));
		}
		return coerceArguments(typed, [for (parameter in parameters) argumentType(parameter, substitutions)], name);
	}

	public function typeGenericCallArguments(fn:AstFunction, arguments:Array<AstExpression>, scope:Scope, span:SourceSpan):{
		arguments:Array<TypedExpression>,
		substitutions:Map<String, CompilerType>
	} {
		var parameters = functionTypeParameters(fn),
			substitutions:Map<String, CompilerType> = [],
			typed:Array<TypedExpression> = [];
		for (index in 0...arguments.length) {
			var expected:Null<CompilerType> = null;
			if (allTypeParametersBound(parameters, substitutions))
				expected = session.declarations.resolve(fn.arguments[index].type, fn.arguments[index].span, substitutions);
			var argument = typeExpression(arguments[index], scope, expected, expected != null);
			inferTypeParameters(fn.arguments[index].type, argument.type, parameters, substitutions, argument.span);
			typed.push(argument);
		}
		return {arguments: typed, substitutions: substitutions};
	}

	public function findMethod(className:String, name:String):Null<SemanticMethodInfo> {
		var results:Array<SemanticMethodInfo> = [];
		findMethods(className, name, results);
		return results.length == 0 ? null : results[0];
	}

	public function resolveInstanceMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, receiverName:Null<String> = null, contextualGenericArguments:Bool = true):TypedExpression {
		var className = switch receiver.type {
			case TInstance(Class, value, _), TInstance(Interface, value, _): value;
			default: null;
		};
		if (className == null)
			fail("E1007", 'Cannot call method on non-object "${receiverName == null ? name : receiverName}"', span);
		var methodInfo = findMethod(className, name);
		if (methodInfo == null || methodInfo.isStatic)
			fail("E1007", 'Unknown instance method "$className.$name"', span);
		var methodOwnerType = projectNominal(receiver.type, methodInfo.owner),
			substitutions = session.representation.nominalSubstitutions(methodOwnerType),
			methodKey = methodInfo.owner + "." + name,
			method = session.signatures.get(methodKey);
		if (method == null)
			fail("E1007", 'Missing signature for method "$methodKey"', span);
		if (functionTypeParameters(method).length > 0) {
			var preset = contextualGenericArguments ? copyMap(substitutions) : new Map<String, CompilerType>(),
				parameters = functionTypeParameters(method),
				hasLambda = false;
			if (!contextualGenericArguments)
				for (argument in arguments)
					switch argument {
						case Lambda(_, _, _):
							hasLambda = true;
						default:
					}
			if (expectedType != null)
				inferTypeParameters(method.result, expectedType, parameters, preset, span);
			var contextual = contextualGenericArguments || hasLambda || expectedType != null,
				typingSubstitutions = copyMap(preset);
			if (contextual)
				for (parameter in parameters)
					if (!typingSubstitutions.exists(parameter))
						typingSubstitutions.set(parameter, TDynamic);
			var genericArguments = contextual ? [
				for (index in 0...arguments.length)
					typeExpression(arguments[index], scope,
						session.declarations.resolve(method.arguments[index].type, method.arguments[index].span, typingSubstitutions), true)
			] : [for (argument in arguments) typeExpression(argument, scope, null, false)];
			return genericInstantiation.specialize(methodKey, method, genericArguments, span, scope, methodInfo.owner, false, preset, receiver);
		}
		var semanticArguments = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span, substitutions),
			physicalArguments = session.representation.adaptMethodArguments(methodOwnerType, methodInfo.owner, method, semanticArguments),
			methodResult = session.representation.resolveMethodResult(methodOwnerType, methodInfo.owner, method),
			call = new TypedExpression(TMethodCall(receiver, methodKey, physicalArguments), methodResult.physical, span),
			castCall = session.representation.boundaryCast(call, methodResult.semantic);
		if (scope != null)
			scope.invalidateAllExpressions();
		return session.noReturnFunctions.exists(methodKey) ? new TypedExpression(TNoReturn(castCall), TNever, castCall.span) : castCall;
	}

	public function typeAbstractMethodCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		var abstractName:String, typeArguments:Array<CompilerType>;
		switch receiver.type {
			case TAbstract(name, arguments, _):
				abstractName = name;
				typeArguments = arguments;
			default:
				return null;
		}
		var declaration = requiredMapValue(session.declarations.abstracts, abstractName),
			method:Null<AstFunction> = null;
		for (candidate in declaration.methods)
			if (candidate.name == name && !candidate.isStatic && candidate.name != "new")
				method = candidate;
		if (method == null)
			fail("E1007", 'Unknown abstract method "$abstractName.$name"', span);
		var methodKey = abstractName + "." + name,
			signature = requiredMapValue(session.signatures, methodKey),
			substitutions = session.representation.typeParameterSubstitutions(declaration.typeParameters, typeArguments);
		if (declaration.isExtern == true) {
			var typed = typeDeclaredCallArguments(arguments, signature.arguments, scope, methodKey, span, substitutions),
				callArguments:Array<TypedExpression> = [
					session.representation.boundaryCast(receiver, session.representation.semanticType(declaration.underlying, declaration.span, substitutions))
				];
			for (argument in typed)
				callArguments.push(argument);
			return new TypedExpression(TCall(methodKey, callArguments), session.representation.semanticType(signature.result, signature.span, substitutions),
				span);
		}
		var typedArguments = [for (argument in arguments) typeExpression(argument, scope, null, false)];
		return genericInstantiation.specialize(methodKey, signature, typedArguments, span, scope, abstractName, false, substitutions, receiver);
	}

	public function typeFunctionFieldCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		var callableFieldType = findCallableFieldType(receiver.type, name);
		if (callableFieldType == null)
			return null;
		return switch callableFieldType {
			case TFunction(argumentTypes, result):
				if (arguments.length != argumentTypes.length)
					fail("E1008", 'Function field "$name" expects ${argumentTypes.length} arguments, got ${arguments.length}', span);
				var typed = [
					for (index in 0...arguments.length)
						typeExpression(arguments[index], scope, argumentTypes[index], false)
				];
				typed = coerceArguments(typed, argumentTypes, name);
				new TypedExpression(TClosureCall(typeCallableField(receiver, name, span), typed), result, span);
			default:
				fail("E1007", 'Cannot call non-function field "$name"', span);
				null;
		};
	}

	public function typeImplicitFunctionFieldCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		var thisType = scope.resolve("this"),
			callableFieldType = thisType == null ? null : findCallableFieldType(thisType, name);
		if (callableFieldType == null)
			return null;
		var fieldCallable = typeExpressionValue(Variable(name, span), scope);
		return switch fieldCallable.type {
			case TFunction(argumentTypes, result):
				if (arguments.length != argumentTypes.length)
					fail("E1008", 'Function field "$name" expects ${argumentTypes.length} arguments, got ${arguments.length}', span);
				var typed = [
					for (index in 0...arguments.length)
						typeExpression(arguments[index], scope, argumentTypes[index], false)
				];
				typed = coerceArguments(typed, argumentTypes, name);
				new TypedExpression(TClosureCall(fieldCallable, typed), result, span);
			default:
				fail("E1007", 'Cannot call non-function field "$name"', span);
				null;
		};
	}

	public function typeClosureCall(callee:AstExpression, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope, callableName:Null<String> = null,
			invalidateAllExpressions:Bool = true):TypedExpression {
		var typedCallee = typeExpression(callee, scope, null, false),
			functionType = switch typedCallee.type {
				case TFunction(parameters, result): {arguments: parameters, result: result};
				default: null;
			};
		if (functionType == null)
			fail("E1007", callableName == null ? "Cannot call non-function expression" : 'Cannot call non-function "$callableName"', span);
		if (arguments.length != functionType.arguments.length)
			fail("E1008",
				callableName == null ? 'Function expression expects ${functionType.arguments.length} arguments, got ${arguments.length}' : 'Function value "$callableName" expects ${functionType.arguments.length} arguments, got ${arguments.length}',
				span);
		var typedArguments = [
			for (index in 0...arguments.length)
				typeExpression(arguments[index], scope, functionType.arguments[index], false)
		];
		typedArguments = coerceArguments(typedArguments, functionType.arguments, callableName == null ? "function expression" : callableName);
		for (captured in session.currentContext.storage.candidateSourceNames())
			scope.invalidate(captured);
		if (invalidateAllExpressions)
			scope.invalidateAllExpressions();
		return new TypedExpression(TClosureCall(typedCallee, typedArguments), functionType.result, span);
	}

	public function resolveFunctionCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var hasSignature = session.signatures.exists(name);
		if (hasSignature && functionTypeParameters(requiredMapValue(session.signatures, name)).length > 0) {
			var signature = requiredMapValue(session.signatures, name),
				infoOwner:Null<String> = null,
				infoStatic = true;
			if (session.methodInfo.exists(name)) {
				var resolvedInfo = requiredMapValue(session.methodInfo, name);
				infoOwner = resolvedInfo.owner;
				infoStatic = resolvedInfo.isStatic;
			}
			var prepared = typeGenericCallArguments(signature, arguments, scope, span);
			return genericInstantiation.specialize(name, signature, prepared.arguments, span, scope, infoOwner, infoStatic, prepared.substitutions);
		}
		var expectedArguments:Array<CompilerType> = [],
			result:CompilerType = TVoid;
		if (hasSignature) {
			var signature = requiredMapValue(session.signatures, name);
			expectedArguments = [for (argument in signature.arguments) argumentType(argument, null)];
			result = lowerType(signature.result);
		} else if (session.externals.exists(name)) {
			var external = requiredMapValue(session.externals, name);
			expectedArguments = external.arguments;
			result = external.result;
		} else
			fail("E1007", 'Unknown function "$name"', span);
		if (!hasSignature && arguments.length != expectedArguments.length)
			fail("E1008", 'Function "$name" expects ${expectedArguments.length} arguments, got ${arguments.length}', span);
		var typed = hasSignature ? typeDeclaredCallArguments(arguments, requiredMapValue(session.signatures, name).arguments, scope, name,
			span) : typeCallArguments(arguments, expectedArguments, scope, name),
			call = new TypedExpression(session.cNativeFunctions.exists(name) ? TCNativeCall(name, typed) : TCall(name, typed), result, span);
		scope.invalidateAllExpressions();
		return session.noReturnFunctions.exists(name) ? new TypedExpression(TNoReturn(call), TNever, call.span) : call;
	}

	public function resolveImplicitMethodCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):Null<TypedExpression> {
		var owner = session.currentContext.lexicalOwner;
		if (name.indexOf(".") >= 0 || owner == null)
			return null;
		var methodInfo = findMethod(owner, name);
		if (methodInfo == null)
			return null;
		var methodKey = methodInfo.owner + "." + name,
			method = session.signatures.get(methodKey);
		if (method == null)
			fail("E1007", 'Missing signature for method "$methodKey"', span);
		if (functionTypeParameters(method).length > 0) {
			var receiver:Null<TypedExpression> = null;
			if (!methodInfo.isStatic) {
				if (scope.resolve("this") == null)
					fail("E1007", 'Instance method "$methodKey" requires an object', span);
				receiver = typeExpressionValue(Variable("this", span), scope);
			}
			var preset:Map<String, CompilerType> = [],
				parameters = functionTypeParameters(method),
				hasLambda = false;
			for (argument in arguments)
				switch argument {
					case Lambda(_, _, _):
						hasLambda = true;
					default:
				}
			if (expectedType != null)
				inferTypeParameters(method.result, expectedType, parameters, preset, span);
			var contextual = hasLambda || expectedType != null,
				typingSubstitutions = copyMap(preset);
			if (contextual)
				for (parameter in parameters)
					if (!typingSubstitutions.exists(parameter))
						typingSubstitutions.set(parameter, TDynamic);
			var genericArguments = contextual ? [
				for (index in 0...arguments.length)
					typeExpression(arguments[index], scope,
						session.declarations.resolve(method.arguments[index].type, method.arguments[index].span, typingSubstitutions), true)
			] : [for (argument in arguments) typeExpression(argument, scope, null, false)];
			return genericInstantiation.specialize(methodKey, method, genericArguments, span, scope, methodInfo.owner, methodInfo.isStatic, preset, receiver);
		}
		if (methodInfo.isStatic) {
			var typed = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span);
			return applyCallEffect(new TypedExpression(TCall(methodKey, typed), lowerType(method.result), span), methodKey, scope);
		}
		if (scope.resolve("this") == null)
			fail("E1007", 'Instance method "$methodKey" requires an object', span);
		var receiver = typeExpressionValue(Variable("this", span), scope),
			methodOwnerType = projectNominal(receiver.type, methodInfo.owner),
			substitutions = session.representation.nominalSubstitutions(methodOwnerType),
			semanticArguments = typeDeclaredCallArguments(arguments, method.arguments, scope, methodKey, span, substitutions),
			physicalArguments = session.representation.adaptMethodArguments(methodOwnerType, methodInfo.owner, method, semanticArguments),
			methodResult = session.representation.resolveMethodResult(methodOwnerType, methodInfo.owner, method),
			call = new TypedExpression(TMethodCall(receiver, methodKey, physicalArguments), methodResult.physical, span);
		return applyCallEffect(session.representation.boundaryCast(call, methodResult.semantic), methodKey, scope);
	}

	public function typeNamedCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		if (scope.resolve(name) != null)
			return typeClosureCall(Variable(name, span), arguments, span, scope, name, false);
		if (name.indexOf(".") < 0) {
			var fieldCall = typeImplicitFunctionFieldCall(name, arguments, span, scope);
			if (fieldCall != null)
				return fieldCall;
			var methodCall = resolveImplicitMethodCall(name, arguments, span, scope, expectedType);
			if (methodCall != null)
				return methodCall;
		}
		var parts = splitPath(name),
			receiverName:Null<String> = null,
			receiver:Null<TypedExpression> = null,
			methodName:Null<String> = null;
		if (parts.length >= 2) {
			methodName = parts[parts.length - 1];
			if (!session.signatures.exists(name)) {
				receiverName = parts[0];
				receiver = resolveCallReceiver(receiverName, span, scope);
			}
		}
		if (receiver != null && parts.length > 2)
			for (index in 1...parts.length - 1)
				receiver = typeCallMemberWithFlow(receiver, parts[index], span, scope);
		if (receiver != null)
			receiver = unwrapNullable(receiver);
		var enumCase = enumCaseInfo(name);
		if (enumCase == null) {
			var expectedEnumName = enumName(expectedType);
			var constructorName = name.indexOf(".") < 0 ? name : compiler.QualifiedName.last(name);
			if (expectedEnumName != null)
				enumCase = enumCaseInfo(expectedEnumName + "." + constructorName);
			if (enumCase == null && name.indexOf(".") < 0)
				enumCase = uniqueEnumCaseInfo(constructorName, arguments.length);
		}
		if (enumCase != null)
			return typeEnumConstructor(name, arguments, expectedType, enumCase, span, scope);
		if (receiver != null && methodName != null)
			return typeMethodCall(receiver, methodName, arguments, span, scope, expectedType, false, receiverName, false);
		return resolveFunctionCall(name, arguments, span, scope);
	}

	function typeEnumConstructor(name:String, arguments:Array<AstExpression>, expectedType:Null<CompilerType>, enumCase:EnumConstructorInfo, span:SourceSpan,
			scope:Scope):TypedExpression {
		var expected = [
			for (parameter in enumCase.params)
				enumParameterType(enumCase.typeParameters, parameter, expectedType)
		], required = requiredEnumParameters(enumCase.params);
		if (arguments.length < required || arguments.length > expected.length)
			fail("E1008", 'Enum constructor "$name" expects $required to ${expected.length} arguments, got ${arguments.length}', span);
		var typedArguments = [
			for (index in 0...arguments.length)
				typeExpression(arguments[index], scope, expected[index], false)
		];
		while (typedArguments.length < expected.length)
			typedArguments.push(new TypedExpression(TNullLiteral, TNull, span));
		typedArguments = coerceArguments(typedArguments, expected, name);
		for (index in 0...typedArguments.length)
			typedArguments[index] = session.representation.boundaryCast(typedArguments[index],
				session.representation.enumStorageType(enumCase.typeParameters, enumCase.params[index]));
		var resultType:CompilerType = TInstance(NominalKind.Enum, enumCase.enumName, []);
		if (expectedType != null && enumName(expectedType) == enumCase.enumName)
			resultType = expectedType;
		return new TypedExpression(TEnumConstruct(enumCase.enumName, enumCase.index, typedArguments), resultType, span);
	}

	function enumCaseInfo(name:String):Null<EnumConstructorInfo> {
		var separator = name.lastIndexOf(".");
		if (separator < 0)
			return null;
		var enumName = name.substring(0, separator),
			caseName = name.substring(separator + 1);
		if (!session.enumDecls.exists(enumName))
			return null;
		var declaration = requiredMapValue(session.enumDecls, enumName);
		for (index in 0...declaration.cases.length)
			if (declaration.cases[index].name == caseName)
				return {
					enumName: enumName,
					index: index,
					params: declaration.cases[index].params,
					typeParameters: declaration.typeParameters
				};
		return null;
	}

	function uniqueEnumCaseInfo(name:String, argumentCount:Int):Null<EnumConstructorInfo> {
		var found:Null<EnumConstructorInfo> = null;
		for (enumName => declaration in session.enumDecls)
			for (index in 0...declaration.cases.length) {
				var enumCase = declaration.cases[index];
				if (enumCase.name != name
					|| argumentCount < requiredEnumParameters(enumCase.params)
					|| argumentCount > enumCase.params.length)
					continue;
				if (found != null)
					return null;
				found = {
					enumName: enumName,
					index: index,
					params: enumCase.params,
					typeParameters: declaration.typeParameters
				};
			}
		return found;
	}

	function enumParameterType(typeParameters:Array<String>, parameter:AstEnumParameter, instance:Null<CompilerType>):CompilerType {
		return session.representation.enumParameterType(typeParameters, parameter, instance);
	}

	static function requiredEnumParameters(parameters:Array<AstEnumParameter>):Int {
		var minimum = 0;
		for (index in 0...parameters.length)
			if (!parameters[index].optional)
				minimum = index + 1;
		return minimum;
	}

	static function enumName(type:Null<CompilerType>):Null<String>
		return switch enumInstance(type) {
			case TInstance(Enum, name, _): name;
			default: null;
		};

	static function enumInstance(type:Null<CompilerType>):Null<CompilerType>
		return switch type {
			case TInstance(Enum, _, _): type;
			case TNullable(inner), TAbstract(_, _, inner): enumInstance(inner);
			default: null;
		};

	static function splitPath(path:String):Array<String>
		return path.split(".");

	static function unwrapNullable(value:TypedExpression):TypedExpression
		return switch value.type {
			case TNullable(element): new TypedExpression(value.expression, element, value.span);
			default: value;
		};

	public function typeSuperCall(arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var owner = session.currentContext.lexicalOwner,
			baseType:Null<AstType> = null;
		if (owner != null && session.classDecls.exists(owner))
			baseType = requiredMapValue(session.classDecls, owner).base;
		if (baseType == null)
			fail("E1007", "super() requires a base-class constructor", span);
		var baseInstance = session.declarations.resolve(baseType, span, session.currentContext.typeSubstitutions),
			resolvedBase = switch baseInstance {
				case TInstance(_, name, _): name;
				default: "";
			},
			substitutions = session.representation.nominalSubstitutions(baseInstance),
			constructorName = resolvedBase + ".new",
			hasConstructor = session.signatures.exists(constructorName),
			expected = PlatformAbi.constructorArguments(resolvedBase),
			resolvedExpected:Array<CompilerType> = [];
		if (expected != null)
			resolvedExpected = expected;
		if (!hasConstructor && arguments.length != resolvedExpected.length)
			fail("E1008", 'Constructor "$resolvedBase" expects ${resolvedExpected.length} arguments, got ${arguments.length}', span);
		var semanticArguments = hasConstructor ? typeDeclaredCallArguments(arguments, requiredMapValue(session.signatures, constructorName).arguments, scope,
			constructorName, span, substitutions) : typeCallArguments(arguments, resolvedExpected, scope, constructorName),
			method = hasConstructor ? requiredMapValue(session.signatures, constructorName) : null,
			physicalArguments = session.representation.adaptConstructorArguments(baseInstance, resolvedBase, method, semanticArguments);
		return new TypedExpression(TSuperCall(resolvedBase, physicalArguments), TVoid, span);
	}

	public function typeRuntimeDataCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		if (name == "RuntimeData.address" || name == "runtime.RuntimeData.address") {
			if (arguments.length != 1)
				fail("E1008", 'RuntimeData.address expects 1 argument, got ${arguments.length}', span);
			return new TypedExpression(TRuntimeDataAddress(runtimeDataBytes(arguments[0], span)), TInt, span);
		}
		if (name == "RuntimeData.loadI32" || name == "runtime.RuntimeData.loadI32") {
			if (arguments.length != 1)
				fail("E1008", 'RuntimeData.loadI32 expects 1 argument, got ${arguments.length}', span);
			var address = coerce(typeExpressionValue(arguments[0], scope), TInt, "runtime data address", "E1002");
			return new TypedExpression(TCall("runtime.RuntimeData.loadI32", [address]), TInt, span);
		}
		return null;
	}

	public function typeBuiltinCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType> = null):Null<TypedExpression> {
		if (name == "MessagePack.encode" || name == "haxe.wire.MessagePack.encode") {
			if (arguments.length != 1)
				fail("E1008", 'Function "$name" expects 1 argument, got ${arguments.length}', span);
			var value = typeExpressionValue(arguments[0], scope);
			WireCodecGenerator.request(session, value.type, session.currentContext.name, span);
			return new TypedExpression(TCall(WireCodecGenerator.encodeName(value.type), [value]), TBytes, span);
		}
		if (name == "MessagePack.decode" || name == "haxe.wire.MessagePack.decode") {
			if (arguments.length != 1)
				fail("E1008", 'Function "$name" expects 1 argument, got ${arguments.length}', span);
			if (expectedType == null || expectedType == TNull)
				fail("E1009", "MessagePack.decode requires an expected result type", span);
			var bytes = coerce(typeExpressionValue(arguments[0], scope), TBytes, "MessagePack.decode input", "E1002"),
				resultType = cast expectedType;
			WireCodecGenerator.request(session, resultType, session.currentContext.name, span);
			return new TypedExpression(TCall(WireCodecGenerator.decodeName(resultType), [bytes]), resultType, span);
		}
		if (name == "Type.enumEq") {
			if (arguments.length != 2)
				fail("E1008", 'Function "Type.enumEq" expects 2 arguments, got ${arguments.length}', span);
			var leftValue = typeExpressionValue(arguments[0], scope),
				rightValue = typeExpression(arguments[1], scope, leftValue.type, false),
				left = coerce(leftValue, TDynamic, "Type.enumEq value", "E1002"),
				right = coerce(rightValue, TDynamic, "Type.enumEq value", "E1002");
			// Type.enumEq is a dynamic equality operation at runtime.  Keep the
			// source-level builtin in the typer, but lower it through the shared
			// intrinsic so every backend has one verified call signature.
			return new TypedExpression(TCall("__dynamic_equal", [left, right]), TBool, span);
		}
		if (name == "Std.isOfType") {
			if (arguments.length != 2)
				fail("E1008", 'Function "Std.isOfType" expects 2 arguments, got ${arguments.length}', span);
			var targetName = switch arguments[1] {
				case Variable(value, _): value;
				default:
					fail("E1009", "Std.isOfType expects a type as its second argument", span);
					"";
			};
			if (scope.resolve(targetName) != null)
				fail("E1009", "Std.isOfType expects a type as its second argument", span);
			var targetType:CompilerType = switch targetName {
				case "Int": TInt;
				case "Float": TFloat;
				case "Bool": TBool;
				case "String": TString;
				case "Array": TArray(TDynamic);
				default:
					if (!session.classDecls.exists(targetName)
						&& !session.interfaceDecls.exists(targetName)
						&& !session.enumDecls.exists(targetName))
						fail("E1007", 'Unknown type "$targetName"', span);
					session.declarations.resolve(NamedType(targetName), span);
			};
			var value = coerce(typeExpressionValue(arguments[0], scope), TDynamic, "Std.isOfType value", "E1002"),
				target = new TypedExpression(TClassRef(targetName), targetType, span);
			return new TypedExpression(TCall("__std_is_of_type", [value, target]), TBool, span);
		}
		if (name == "Reflect.compare") {
			if (arguments.length != 2)
				fail("E1008", 'Function "Reflect.compare" expects 2 arguments, got ${arguments.length}', span);
			var left = typeExpressionValue(arguments[0], scope),
				right = typeExpression(arguments[1], scope, left.type, false);
			if (sameType(left.type, TString) && sameType(right.type, TString))
				return new TypedExpression(TCall("__string_compare_full", [left, right]), TInt, span);
			return null;
		}
		if (name == "Reflect.isObject") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Reflect.isObject" expects 1 argument, got ${arguments.length}', span);
			var value = coerce(typeExpressionValue(arguments[0], scope), TDynamic, "Reflect.isObject value", "E1002");
			return new TypedExpression(TCall("__reflect_is_object", [value]), TBool, span);
		}
		if (name == "Math.ceil") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Math.ceil" expects 1 argument, got ${arguments.length}', span);
			var value = coerce(typeExpressionValue(arguments[0], scope), TFloat, "Math.ceil value", "E1002");
			return new TypedExpression(TCall("__math_ceil", [value]), TInt, span);
		}
		if (name == "haxe.io.Bytes.ofString") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "haxe.io.Bytes.ofString" expects 1 or 2 arguments, got ${arguments.length}', span);
			var value = coerce(typeExpression(arguments[0], scope, TString, false), TString, "byte string", "E1002");
			return new TypedExpression(TCall("haxe.io.Bytes.ofString", [value]), TBytes, span);
		}
		if (name == "Std.int" || name == "Std.stdIntFloat") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Std.int" expects 1 argument, got ${arguments.length}', span);
			var value = typeExpression(arguments[0], scope, name == "Std.stdIntFloat" ? TFloat : null, false);
			return switch value.type {
				case TInt: value;
				case TFloat: new TypedExpression(TCall("__std_int_f64", [value]), TInt, span);
				case TDynamic: new TypedExpression(TCall("__std_int_dynamic", [value]), TInt, span);
				default:
					fail("E1009", "Std.int expects an Int or Float", value.span);
					new TypedExpression(TIntLiteral(0), TInt, span);
			};
		}
		if (name == "Std.stdString") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Std.string" expects 1 argument, got ${arguments.length}', span);
			var value = coerce(typeExpressionValue(arguments[0], scope), TDynamic, "Std.string value", "E1002");
			return new TypedExpression(TCall("__std_string", [value]), TString, span);
		}
		if (name == "String.__alloc__") {
			if (arguments.length != 2)
				fail("E1008", 'Function "String.__alloc__" expects 2 arguments, got ${arguments.length}', span);
			var bytes = typeExpressionValue(arguments[0], scope);
			switch bytes.type {
				case THlBytes, TAbstract(_, _, THlBytes):
				default:
					fail("E1009", "String.__alloc__ expects hl.Bytes data", bytes.span);
			}
			bytes = session.representation.boundaryCast(bytes, THlBytes);
			var length = typeExpression(arguments[1], scope, TInt, false);
			if (!sameType(length.type, TInt))
				fail("E1009", "String.__alloc__ expects an Int length", length.span);
			return new TypedExpression(TCall("__string_from_bytes", [bytes, length]), TString, span);
		}
		if (name == "String.fromCharCode") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.fromCharCode" expects 1 argument, got ${arguments.length}', span);
			var code = typeExpression(arguments[0], scope, TInt, false);
			if (!sameType(code.type, TInt))
				fail("E1009", "String.fromCharCode expects an Int code", code.span);
			return new TypedExpression(TStringFromCharCode(code), TString, span);
		}
		return null;
	}

	function runtimeDataBytes(expression:AstExpression, span:SourceSpan):Array<Int> {
		var chunks = switch expression {
			case ArrayLiteral(values, _): values;
			default:
				fail("E1009", "RuntimeData.address requires an array of hexadecimal string literals", span);
				[];
		};
		var hex = new StringBuf();
		for (chunk in chunks)
			switch chunk {
				case StringLiteral(value, _):
					hex.add(value);
				default:
					fail("E1009", "RuntimeData.address requires an array of hexadecimal string literals", span);
			}
		var encoded = hex.toString();
		if (encoded.length == 0 || (encoded.length & 7) != 0)
			fail("E1009", "RuntimeData.address data must contain complete 32-bit hexadecimal words", span);
		var result:Array<Int> = [];
		for (index in 0...Std.int(encoded.length / 2)) {
			var high = runtimeDataHexDigit(encoded.charCodeAt(index * 2)),
				low = runtimeDataHexDigit(encoded.charCodeAt(index * 2 + 1));
			if (high < 0 || low < 0)
				fail("E1009", "RuntimeData.address data contains a non-hexadecimal character", span);
			result.push((high << 4) | low);
		}
		return result;
	}

	static function runtimeDataHexDigit(code:Int):Int
		return code >= 48 && code <= 57 ? code - 48 : code >= 65 && code <= 70 ? code - 55 : code >= 97 && code <= 102 ? code - 87 : -1;

	function applyCallEffect(call:TypedExpression, name:String, ?scope:Scope):TypedExpression {
		if (scope != null)
			scope.invalidateAllExpressions();
		return session.noReturnFunctions.exists(name) ? new TypedExpression(TNoReturn(call), TNever, call.span) : call;
	}

	function projectNominal(type:CompilerType, target:String):CompilerType {
		var projected = session.declarations.inheritance.project(type, target);
		return projected == null ? type : projected;
	}

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);

	static function isArray(type:CompilerType):Bool
		return switch type {
			case TArray(_): true;
			default: false;
		};

	static function isIterator(type:CompilerType):Bool
		return switch type {
			case TIterator(_): true;
			default: false;
		};

	static function isMap(type:CompilerType):Bool
		return switch type {
			case TMap(_, _): true;
			default: false;
		};

	static function copyMap<T>(source:Map<String, T>):Map<String, T> {
		var result:Map<String, T> = [];
		for (key => value in source)
			result.set(key, value);
		return result;
	}

	function findMethods(className:String, name:String, results:Array<SemanticMethodInfo>):Void {
		if (results.length > 0)
			return;
		var key = className + "." + name;
		if (session.methodInfo.exists(key)) {
			results.push(requiredMapValue(session.methodInfo, key));
			return;
		}
		if (session.classDecls.exists(className)) {
			var base = requiredMapValue(session.classDecls, className).base;
			if (base != null)
				findMethods(inheritanceName(base), name, results);
			return;
		}
		if (session.interfaceDecls.exists(className))
			for (base in requiredMapValue(session.interfaceDecls, className).bases)
				findMethods(inheritanceName(base), name, results);
	}

	public function typeStringMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		if (!sameType(receiver.type, TString))
			return null;
		if (name == "toLowerCase") {
			if (arguments.length != 0)
				fail("E1008", 'Function "String.toLowerCase" expects no arguments, got ${arguments.length}', span);
			return new TypedExpression(TCall("__string_to_lower_case", [receiver]), TString, span);
		}
		if (name == "toUpperCase") {
			if (arguments.length != 0)
				fail("E1008", 'Function "String.toUpperCase" expects no arguments, got ${arguments.length}', span);
			return new TypedExpression(TCall("__string_to_upper_case", [receiver]), TString, span);
		}
		if (name == "indexOf") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "String.indexOf" expects 1 or 2 arguments, got ${arguments.length}', span);
			var needle = coerce(typeExpressionValue(arguments[0], scope, TString), TString, "String.indexOf needle", "E1009");
			if (arguments.length == 1)
				return new TypedExpression(TStringIndexOf(receiver, needle), TInt, span);
			var start = coerce(typeExpressionValue(arguments[1], scope, TInt), TInt, "String.indexOf start index", "E1009");
			return new TypedExpression(TCall("__string_index_of_from", [receiver, needle, start]), TInt, span);
		}
		if (name == "lastIndexOf") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "String.lastIndexOf" expects 1 or 2 arguments, got ${arguments.length}', span);
			var needle = coerce(typeExpressionValue(arguments[0], scope, TString), TString, "String.lastIndexOf needle", "E1009");
			if (arguments.length == 1)
				return new TypedExpression(TCall("__string_last_index_of", [receiver, needle]), TInt, span);
			var start = coerce(typeExpressionValue(arguments[1], scope, TInt), TInt, "String.lastIndexOf start index", "E1009");
			return new TypedExpression(TCall("__string_last_index_of_from", [receiver, needle, start]), TInt, span);
		}
		if (name == "substring" || name == "substr") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "String.$name" expects 1 or 2 arguments, got ${arguments.length}', span);
			var start = coerce(typeExpressionValue(arguments[0], scope, TInt), TInt, 'String.$name start', "E1009"),
				end:Null<TypedExpression> = arguments.length == 1 ? null : coerce(typeExpressionValue(arguments[1], scope, TInt), TInt, 'String.$name end',
					"E1009");
			if (name == "substr" && end != null)
				end = new TypedExpression(TAdd(start, end), TInt, span);
			return new TypedExpression(TStringSubstring(receiver, start, end), TString, span);
		}
		if (name == "charCodeAt") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.charCodeAt" expects 1 argument, got ${arguments.length}', span);
			var index = coerce(typeExpressionValue(arguments[0], scope, TInt), TInt, "String.charCodeAt index", "E1009");
			return new TypedExpression(TStringCharCodeAt(receiver, index), TInt, span);
		}
		if (name == "charAt") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.charAt" expects 1 argument, got ${arguments.length}', span);
			var index = coerce(typeExpressionValue(arguments[0], scope, TInt), TInt, "String.charAt index", "E1009");
			return new TypedExpression(TStringCharAt(receiver, index), TString, span);
		}
		if (name == "split") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.split" expects one argument, got ${arguments.length}', span);
			var separator = coerce(typeExpressionValue(arguments[0], scope, TString), TString, "String.split separator", "E1009");
			return new TypedExpression(TCall("__string_split", [receiver, separator]), TArray(TString), span);
		}
		throw new CompileError(new Diagnostic("E1007", 'Unknown String method "$name"', span));
	}

	public function typeArrayMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var element = switch receiver.type {
			case TArray(value): value;
			default: throw "Not an array";
		};
		if (RuntimeType.arrayName(element) == null)
			fail("E1016", "This array element type has no compiler-owned runtime ABI", span);
		if (name == "push" || name == "add") {
			if (arguments.length != 1)
				fail("E1008", 'Array.$name expects one argument', span);
			var value = coerce(typeExpressionValue(arguments[0], scope, element), element, "array element", "E1002");
			return new TypedExpression(TArrayPush(receiver, value), TInt, span);
		}
		if (name == "iterator") {
			if (arguments.length != 0)
				fail("E1008", "Array.iterator expects no arguments", span);
			return iterator(receiver, element, span);
		}
		if (name == "unshift") {
			if (arguments.length != 1)
				fail("E1008", "Array.unshift expects one argument", span);
			var value = coerce(typeExpressionValue(arguments[0], scope, element), element, "array element", "E1002");
			return new TypedExpression(TArrayUnshift(receiver, value), TInt, span);
		}
		if (name == "pop") {
			if (arguments.length != 0)
				fail("E1008", "Array.pop expects no arguments", span);
			return new TypedExpression(TArrayPop(receiver), element, span);
		}
		if (name == "shift") {
			if (arguments.length != 0)
				fail("E1008", "Array.shift expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "shift", []), element, span);
		}
		if (name == "resize") {
			if (arguments.length != 1)
				fail("E1008", "Array.resize expects one argument", span);
			var length = coerce(typeExpressionValue(arguments[0], scope), TInt, "array length", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "resize", [length]), TVoid, span);
		}
		if (name == "remove") {
			if (arguments.length != 1)
				fail("E1008", "Array.remove expects one argument", span);
			var value = coerce(typeExpressionValue(arguments[0], scope, element), element, "array element", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "remove", [value]), TBool, span);
		}
		if (name == "insert") {
			if (arguments.length != 2)
				fail("E1008", "Array.insert expects a position and value", span);
			var position = coerce(typeExpressionValue(arguments[0], scope), TInt, "insert position", "E1002"),
				value = coerce(typeExpressionValue(arguments[1], scope, element), element, "array element", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "insert", [position, value]), TVoid, span);
		}
		if (name == "reverse") {
			if (arguments.length != 0)
				fail("E1008", "Array.reverse expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "reverse", []), TVoid, span);
		}
		if (name == "copy") {
			if (arguments.length != 0)
				fail("E1008", "Array.copy expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "copy", []), TArray(element), span);
		}
		if (name == "concat") {
			if (arguments.length != 1)
				fail("E1008", "Array.concat expects one argument", span);
			var other = typeExpressionValue(arguments[0], scope, TArray(element)),
				otherElement = arrayElementType(other.type, span);
			if (!sameType(otherElement, element))
				fail("E1002", "Array.concat expects matching element types", span);
			return new TypedExpression(TCollectionCall(receiver, "concat", [other]), TArray(element), span);
		}
		if (name == "slice") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", "Array.slice expects a start and optional end", span);
			var start = coerce(typeExpressionValue(arguments[0], scope), TInt, "slice start", "E1002"),
				end = arguments.length == 2 ? coerce(typeExpressionValue(arguments[1], scope), TInt, "slice end",
					"E1002") : new TypedExpression(TArrayLength(receiver), TInt, span);
			return new TypedExpression(TCollectionCall(receiver, "slice", [start, end]), TArray(element), span);
		}
		if (name == "splice") {
			if (arguments.length != 2)
				fail("E1008", "Array.splice expects a position and length", span);
			var position = coerce(typeExpressionValue(arguments[0], scope), TInt, "splice position", "E1002"),
				length = coerce(typeExpressionValue(arguments[1], scope), TInt, "splice length", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "splice", [position, length]), TArray(element), span);
		}
		if (name == "sort") {
			if (arguments.length != 1)
				fail("E1008", "Array.sort expects one comparator", span);
			var comparatorType = CompilerType.TFunction([element, element], TInt),
				comparator = coerce(typeExpressionValue(arguments[0], scope, comparatorType), comparatorType, "array comparator", "E1002");
			return new TypedExpression(TArraySort(receiver, comparator), TVoid, span);
		}
		if (name == "join") {
			if (!sameType(element, TString))
				fail("E1016", "Array.join currently requires String elements", span);
			if (arguments.length != 1)
				fail("E1008", "Array.join expects one separator", span);
			var separator = coerce(typeExpressionValue(arguments[0], scope, TString), TString, "join separator", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "join", [separator]), TString, span);
		}
		if (name == "indexOf") {
			switch element {
				case TInt, TFloat, TBool, TString:
				default:
					if (RuntimeType.arrayName(element) != "ref")
						fail("E1016", "Array.indexOf currently supports primitive, String, and reference arrays only", span);
			}
			if (arguments.length != 1)
				fail("E1008", "Array.indexOf expects one argument", span);
			var value = coerce(typeExpressionValue(arguments[0], scope), element, "array element", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "index_of", [value]), TInt, span);
		}
		if (name == "contains") {
			if (arguments.length != 1)
				fail("E1008", "Array.contains expects one argument", span);
			var value = coerce(typeExpressionValue(arguments[0], scope), element, "array element", "E1002"),
				index = new TypedExpression(TCollectionCall(receiver, "index_of", [value]), TInt, span),
				zero = new TypedExpression(TIntLiteral(0), TInt, span);
			return new TypedExpression(TLessEqual(zero, index), TBool, span);
		}
		throw new CompileError(new Diagnostic("E1007", 'Unknown array method "$name"', span));
	}

	function iterator(values:TypedExpression, element:CompilerType, span:SourceSpan):TypedExpression {
		var dynamicValues = coerce(values, TDynamic, "iterator source", "E1014");
		return new TypedExpression(TCall("__iterator_new", [dynamicValues]), TIterator(element), span);
	}

	public static function mapKeyIteratorSource(value:TypedExpression):Null<TypedExpression>
		return switch value.expression {
			case TCollectionCall(map, "keys", []): map;
			case TCall("__iterator_new", [source]), TToDynamic(source), TCast(source), TAbiCast(source): mapKeyIteratorSource(source);
			default: null;
		};

	public function typeIteratorMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan):TypedExpression {
		if (arguments.length != 0)
			fail("E1008", 'Iterator.$name expects no arguments', span);
		return switch name {
			case "hasNext": new TypedExpression(TCall("__iterator_has_next", [receiver]), TBool, span);
			case "next":
				var element = switch receiver.type {
					case TIterator(value): value;
					default: throw "Not an iterator";
				};
				new TypedExpression(TCall("__iterator_next", [receiver]), element, span);
			default: throw new CompileError(new Diagnostic("E1007", 'Unknown Iterator method "$name"', span));
		};
	}

	function hasInstanceField(type:CompilerType, name:String):Bool
		return switch type {
			case TInstance(Class, className, []):
				var found = false;
				if (session.classDecls.exists(className)) {
					var classDecl = requiredMapValue(session.classDecls, className);
					for (field in classDecl.fields)
						if (field.name == name && !field.isStatic)
							found = true;
					var base = classDecl.base;
					if (!found && base != null)
						found = hasInstanceField(TInstance(NominalKind.Class, inheritanceName(base), []), name);
				}
				found;
			default: false;
		};

	public function typeMapMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var mapType = switch receiver.type {
			case TMap(key, value): {key: key, value: value};
			default: throw "Not a map";
		};
		if (session.mapName(mapType.key, mapType.value) == null)
			fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
		if (name == "set") {
			if (arguments.length != 2)
				fail("E1008", "Map.set expects a key and value", span);
			var key = coerce(typeExpressionValue(arguments[0], scope, mapType.key), mapType.key, "map key", "E1002"),
				value = coerce(typeExpressionValue(arguments[1], scope, mapType.value), mapType.value, "map value", "E1002");
			var entryPath = FlowAnalysis.mapEntryPath(receiver, key);
			if (entryPath != null)
				scope.refineExpression(entryPath, mapType.value);
			return new TypedExpression(TCollectionCall(receiver, "set", [key, value]), TVoid, span);
		}
		if (name == "copy") {
			if (arguments.length != 0)
				fail("E1008", "Map.copy expects no arguments", span);
			var keyName = '$' + 'map-copy-key:${span.start}',
				valueName = '$' + 'map-copy-value:${span.start}';
			return new TypedExpression(TMapComprehension(keyName, valueName, receiver, null, new TypedExpression(TLocal(keyName), mapType.key, span),
				new TypedExpression(TLocal(valueName), mapType.value, span)),
				receiver.type, span);
		}
		if (name == "keys") {
			if (arguments.length != 0)
				fail("E1008", "Map.keys expects no arguments", span);
			var values = new TypedExpression(TCollectionCall(receiver, "keys", []), TArray(mapType.key), span);
			return iterator(values, mapType.key, span);
		}
		if (name == "values") {
			if (arguments.length != 0)
				fail("E1008", "Map.values expects no arguments", span);
			var values = new TypedExpression(TCollectionCall(receiver, "values", []), TArray(mapType.value), span);
			return iterator(values, mapType.value, span);
		}
		if (name == "iterator") {
			if (arguments.length != 0)
				fail("E1008", "Map.iterator expects no arguments", span);
			var values = new TypedExpression(TCollectionCall(receiver, "values", []), TArray(mapType.value), span);
			return iterator(values, mapType.value, span);
		}
		if (name == "clear") {
			if (arguments.length != 0)
				fail("E1008", "Map.clear expects no arguments", span);
			var entriesPath = FlowAnalysis.mapEntriesPath(receiver);
			if (entriesPath != null)
				scope.invalidateExpressionNamespace(entriesPath);
			return new TypedExpression(TCollectionCall(receiver, "clear", []), TVoid, span);
		}
		if (name == "size") {
			if (arguments.length != 0)
				fail("E1008", "Map.size expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "size", []), TInt, span);
		}
		if (arguments.length != 1)
			fail("E1008", 'Map.$name expects one argument', span);
		var key = coerce(typeExpressionValue(arguments[0], scope, mapType.key), mapType.key, "map key", "E1002");
		return switch name {
			case "exists": new TypedExpression(TCollectionCall(receiver, "exists", [key]), TBool, span);
			case "remove":
				var entryPath = FlowAnalysis.mapEntryPath(receiver, key);
				if (entryPath != null)
					scope.invalidateExpressionValue(entryPath);
				new TypedExpression(TCollectionCall(receiver, "remove", [key]), TBool, span);
			case "get":
				var entryPath = FlowAnalysis.mapEntryPath(receiver, key),
					refined = entryPath == null ? null : scope.resolveExpression(entryPath);
				new TypedExpression(TMapGet(receiver, key), refined == null ? nullableMapValue(mapType.value) : refined, span);
			default: throw new CompileError(new Diagnostic("E1007", 'Unknown map method "$name"', span));
		};
	}

	public static function nullableMapValue(type:CompilerType):CompilerType
		return switch type {
			case TNullable(_): type;
			default: TNullable(type);
		};

	public function typeInferredClassConstruction(typeName:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):TypedExpression {
		var declaration = requiredMapValue(session.classDecls, typeName),
			parameters = declaration.typeParameters,
			substitutions:Map<String, CompilerType> = [];
		var constructorExpectation = switch expectedType {
			case TNullable(element): element;
			default: expectedType;
		};
		var contextualArguments:Null<Array<CompilerType>> = null;
		switch constructorExpectation {
			case TInstance(NominalKind.Class, expectedName, values):
				if (expectedName == typeName)
					contextualArguments = values;
			default:
		}
		if (contextualArguments != null)
			for (index in 0...parameters.length)
				if (index < contextualArguments.length)
					substitutions.set(parameters[index], contextualArguments[index]);

		var constructorName = typeName + ".new",
			hasConstructor = session.signatures.exists(constructorName),
			implicitConstructor = !hasConstructor && [
				for (field in declaration.fields)
					if (!field.isStatic && field.initializer != null) field
			].length > 0;
		if (!hasConstructor) {
			if (arguments.length != 0)
				fail("E1008", 'Constructor "$typeName" expects 0 arguments, got ${arguments.length}', span);
		} else {
			var constructor = requiredMapValue(session.signatures, constructorName),
				required = constructor.arguments.length;
			while (required > 0 && constructor.arguments[required - 1].optional == true)
				required--;
			if (arguments.length < required || arguments.length > constructor.arguments.length) {
				var expected = required == constructor.arguments.length ? '$required' : '$required to ${constructor.arguments.length}';
				fail("E1008", 'Function "$constructorName" expects $expected arguments, got ${arguments.length}', span);
			}
		}

		var typed:Array<TypedExpression> = [],
			constructor = hasConstructor ? requiredMapValue(session.signatures, constructorName) : null;
		for (index in 0...arguments.length) {
			var expectedArgument:Null<CompilerType> = null;
			if (allTypeParametersBound(parameters, substitutions) && constructor != null)
				expectedArgument = session.declarations.resolve(constructor.arguments[index].type, constructor.arguments[index].span, substitutions);
			var argument = typeExpressionValue(arguments[index], scope, expectedArgument);
			if (constructor != null)
				inferTypeParameters(constructor.arguments[index].type, argument.type, parameters, substitutions, argument.span);
			typed.push(argument);
		}
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				fail("E1003", 'Cannot infer generic type parameter "$parameter" for constructor "$typeName"', span);
		validateTypeParameterConstraints(typeName, declaration.typeConstraints, substitutions, span);

		if (constructor != null) {
			var semanticExpected = [
				for (parameter in constructor.arguments)
					argumentType(parameter, substitutions)
			];
			for (index in arguments.length...constructor.arguments.length) {
				var parameter = constructor.arguments[index],
					defaultValue = parameter.defaultValue;
				if (isPosInfosParameter(parameter))
					typed.push(typeExpressionValue(posInfosExpression(span), scope, semanticExpected[index]));
				else if (defaultValue == null)
					typed.push(new TypedExpression(TNullLiteral, TNull, span));
				else
					typed.push(typeDefaultExpression(defaultValue, semanticExpected[index], constructorName));
			}
			typed = coerceArguments(typed, semanticExpected, constructorName);
		}
		var typeArguments = [for (parameter in parameters) requiredMapValue(substitutions, parameter)],
			valueType = TInstance(NominalKind.Class, typeName, typeArguments),
			representationArguments = session.representation.adaptConstructorArguments(valueType, typeName, constructor, typed);
		return new TypedExpression(TNew(typeName, representationArguments, hasConstructor || implicitConstructor), valueType, span);
	}

	/** Resolves explicit and inferred class construction, including abstract constructors. */
	public function typeConstruction(typeName:String, typeArguments:Array<AstType>, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, hasExplicitTypeArguments:Bool):TypedExpression {
		if (session.declarations.abstracts.exists(typeName))
			return typeAbstractConstruction(typeName, typeArguments, arguments, span, scope);
		if (hasExplicitTypeArguments) {
			if (!session.classDecls.exists(typeName) || session.interfaceDecls.exists(typeName))
				fail("E1007", 'Unknown class "$typeName"', span);
			var classDecl = requiredMapValue(session.classDecls, typeName),
				valueType = session.representation.semanticType(AppliedType(typeName, typeArguments), span, session.currentContext.typeSubstitutions),
				substitutions = session.representation.nominalSubstitutions(valueType),
				constructorName = typeName + ".new",
				hasConstructor = session.signatures.exists(constructorName),
				implicitConstructor = !hasConstructor && [
					for (field in classDecl.fields)
						if (!field.isStatic && field.initializer != null) field
				].length > 0;
			if (!hasConstructor && arguments.length != 0)
				fail("E1008", 'Constructor "$typeName" expects 0 arguments, got ${arguments.length}', span);
			var constructor = hasConstructor ? requiredMapValue(session.signatures, constructorName) : null,
				semanticArguments = constructor == null ? [] : typeDeclaredCallArguments(arguments, constructor.arguments, scope, constructorName, span,
					substitutions),
				typed = session.representation.adaptConstructorArguments(valueType, typeName, constructor, semanticArguments);
			return new TypedExpression(TNew(typeName, typed, hasConstructor || implicitConstructor), valueType, span);
		}
		if ((!session.classDecls.exists(typeName) && !PlatformAbi.isType(typeName)) || session.interfaceDecls.exists(typeName))
			fail("E1007", 'Unknown class "$typeName"', span);
		var classDecl = session.classDecls.exists(typeName) ? requiredMapValue(session.classDecls, typeName) : null;
		if (classDecl != null && classDecl.typeParameters.length > 0)
			return typeInferredClassConstruction(typeName, arguments, span, scope, expectedType);
		var constructorName = typeName + ".new",
			hasConstructor = session.signatures.exists(constructorName),
			implicitConstructor = !hasConstructor && classDecl != null && [
				for (field in classDecl.fields)
					if (!field.isStatic && field.initializer != null) field
			].length > 0;
		var expected = hasConstructor ? [
			for (argument in requiredMapValue(session.signatures, constructorName).arguments)
				argumentType(argument, null)
		] : PlatformAbi.constructorArguments(typeName), resolvedExpected:Array<CompilerType> = [];
		if (expected != null)
			resolvedExpected = expected;
		if (!hasConstructor && arguments.length != resolvedExpected.length)
			fail("E1008", 'Constructor "$typeName" expects ${resolvedExpected.length} arguments, got ${arguments.length}', span);
		var typed = hasConstructor ? typeDeclaredCallArguments(arguments, requiredMapValue(session.signatures, constructorName).arguments, scope,
			constructorName, span) : typeCallArguments(arguments, resolvedExpected, scope, constructorName),
			nativeConstructor = PlatformAbi.constructorNative(typeName),
			valueType = PlatformAbi.valueType(typeName);
		return nativeConstructor == null ? new TypedExpression(TNew(typeName, typed, hasConstructor || implicitConstructor), valueType,
			span) : new TypedExpression(TCall(nativeConstructor, typed), valueType, span);
	}

	function typeAbstractConstruction(name:String, typeArguments:Array<AstType>, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope):TypedExpression {
		var decl = requiredMapValue(session.declarations.abstracts, name),
			valueType = typeArguments.length == 0 ? session.representation.semanticType(NamedType(name), span,
				session.currentContext.typeSubstitutions) : session.representation.semanticType(AppliedType(name, typeArguments), span,
					session.currentContext.typeSubstitutions),
			constructorName = name + ".new",
			constructor = session.signatures.get(constructorName);
		if (constructor == null)
			fail("E1007", 'Abstract "$name" has no constructor', span);
		if (decl.isExtern == true) {
			var typed = typeDeclaredCallArguments(arguments, constructor.arguments, scope, constructorName, span);
			return new TypedExpression(TCall(constructorName, typed), valueType, span);
		}
		var substitutions = switch valueType {
			case TAbstract(_, appliedArguments, _):
				session.representation.typeParameterSubstitutions(decl.typeParameters, appliedArguments);
			default: new Map<String, CompilerType>();
		}, representation = session.representation.abstractUnderlying(valueType);
		var normalized = AbstractConstructorNormalizer.normalize(constructor, decl.underlying),
			typedArguments = [for (argument in arguments) typeExpression(argument, scope, null, false)],
			constructed:TypedExpression;
		try {
			constructed = genericInstantiation.specialize(constructorName, normalized, typedArguments, span, scope, name, true, substitutions);
		} catch (error:CompileError) {
			var message = error.diagnostic.message;
			if (StringTools.startsWith(message, 'Type mismatch for local "' + AbstractConstructorNormalizer.RESULT_PREFIX))
				fail("E1003", 'Type mismatch for abstract constructor "$constructorName"', error.diagnostic.span);
			if (StringTools.startsWith(message, 'Local "' + AbstractConstructorNormalizer.RESULT_PREFIX)
				&& message.indexOf("may be used before assignment") >= 0)
				fail("E1023", 'Abstract constructor "$constructorName" does not initialize this on every path', error.diagnostic.span);
			throw error;
		}
		return session.representation.boundaryCast(coerce(constructed, representation, 'abstract constructor "$constructorName"', "E1003"), valueType);
	}

	static function allTypeParametersBound(parameters:Array<String>, substitutions:Map<String, CompilerType>):Bool {
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				return false;
		return true;
	}

	function validateTypeParameterConstraints(name:String, constraints:Null<Array<AstTypeConstraint>>, substitutions:Map<String, CompilerType>,
			span:SourceSpan):Void {
		if (constraints == null)
			return;
		for (constraint in constraints) {
			var actual = requiredMapValue(substitutions, constraint.parameter),
				expected = session.declarations.resolve(constraint.type, constraint.span, substitutions);
			if (!session.relations.isAssignable(actual, expected))
				fail("E1003", 'Type argument for "${constraint.parameter}" on "$name" does not satisfy constraint "${SemanticSignature.type(expected)}"', span);
		}
	}

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw 'Missing map entry "$name"';
		return source.get(name);
	}

	public static function isPosInfosParameter(argument:AstArgument):Bool
		return argument.optional == true && switch argument.type {
			case NamedType("haxe.PosInfos"): true;
			default: false;
		};

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
