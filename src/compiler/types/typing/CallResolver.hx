package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.NativeLayout;
import compiler.runtime.ArrayLibrary;
import compiler.runtime.PlatformAbi;
import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstEnumParameter;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstTypeConstraint;
import compiler.syntax.Ast.AstSwitchExpressionCase;
import compiler.syntax.AstPredicates;
import compiler.semantic.SemanticProgram.SemanticMethodInfo;
import compiler.types.FunctionTypes;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.analysis.Scope;
import compiler.types.analysis.ClosureEffects;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.AbstractConstructorNormalizer;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypeRelations;
import compiler.types.DeclarationIndex;
import compiler.semantic.SemanticSignature;
import compiler.semantic.StaticExtensionTable.StaticExtensionOwnerKind;
import compiler.syntax.Ast.TemporaryLocal;

typedef EnumConstructorInfo = {
	?aliasType:CompilerType,
	?aliasName:String,
	enumName:String,
	index:Int,
	params:Array<AstEnumParameter>,
	typeParameters:Array<String>
};

/** Resolves callable lookup, dispatch, construction, and source arguments. */
class CallResolver {
	final session:TypingSession;
	final genericInstantiation:GenericInstantiation;
	final bodyTyper:BodyTyping;
	final staticExtensions:StaticExtensions;

	public function new(session:TypingSession, genericInstantiation:GenericInstantiation, bodyTyper:BodyTyping) {
		this.session = session;
		this.genericInstantiation = genericInstantiation;
		this.bodyTyper = bodyTyper;
		this.staticExtensions = new StaticExtensions(session, genericInstantiation);
	}

	public function coerceArguments(arguments:Array<TypedExpression>, expected:Array<CompilerType>,
			name:String):Array<TypedExpression> {
		var output:Array<TypedExpression> = [];
		for (i in 0...arguments.length)
			output.push(bodyTyper.coerce(arguments[i], expected[i], 'argument ${i + 1} to "$name"'));
		return output;
	}

	public function typeCallArguments(arguments:Array<AstExpression>, expected:Array<CompilerType>, scope:Scope,
			name:String):Array<TypedExpression> {
		var typed = [
			for (i in 0...arguments.length)
				bodyTyper.typeExpression(arguments[i], scope, expected[i])
		];
		return coerceArguments(typed, expected, name);
	}

	/** Resolve an abstract's declared @:op method using the semantic operand types. */
	public function typeAbstractOperator(symbol:String, operands:Array<TypedExpression>, span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		if ((symbol == "|" || symbol == "&") && operands.length == 2)
			for (operand in operands)
				switch operand.type {
					case TAbstract(owner, _, _):
						var declaration = session.enumAbstractDecls.get(owner);
						if (declaration != null && FlagsGenerator.conforms(session, declaration)) {
							if (!sameType(operands[0].type, operand.type) || !sameType(operands[1].type, operand.type))
								fail("E1010", "Flags operators require two values of the same flags type", span);
							return new TypedExpression(TCall(FlagsGenerator.request(session, owner,
								symbol == "|" ? "$or" : "$and", span), operands),
								operand.type, span);
						}
					default:
				}

		var owners:Array<String> = [];
		for (operand in operands)
			switch operand.type {
				case TAbstract(name, _, underlying):
					if (((switch (underlying) {
						case TInt: true;
						default: false;
					}) || (switch (underlying) {
						case TFloat: true;
						default: false;
					})) && owners.indexOf(name) < 0)
						owners.push(name);
				default:
			}
		var selected:Null<{
			key:String,
			method:AstFunction,
			expected:Array<CompilerType>,
			score:Int
		}> = null,
			ambiguous:Null<String> = null;
		for (owner in owners) {
			var declaration = session.declarations.abstractDeclaration(owner);
			if (declaration == null)
				throw new InternalError('Missing abstract declaration "$owner"');
			for (method in declaration.methods) {
				if (method.arguments.length != operands.length
					|| !DeclarationIndex.methodDeclaresOperator(method, symbol))
					continue;
				var expected = bodyTyper.argumentTypesOf(method),
					score = 0,
					compatible = true;
				for (index in 0...operands.length) {
					if (TypeRelations.equals(operands[index].type, expected[index]))
						score++;
					else if (!session.relations.isAssignable(operands[index].type, expected[index]))
						compatible = false;
				}
				if (!compatible)
					continue;
				var key = owner + "." + method.name;
				if (selected != null && selected.score == score && ambiguous == null)
					ambiguous = key;
				if (selected == null || score > selected.score) {
					ambiguous = null;
					selected = {
						key: key,
						method: method,
						expected: expected,
						score: score
					};
				}
			}
		}
		if (selected == null)
			return null;
		if (ambiguous != null)
			fail("E1010", 'Ambiguous abstract operator "$symbol" between "${selected.key}" and "$ambiguous"', span);
		var resultType = bodyTyper.lowerType(selected.method.result, selected.method.span);
		if ((symbol == "<" || symbol == "<=" || symbol == ">" || symbol == ">=" || symbol == "==" || symbol == "!=")
			&& (switch (resultType) {
				case TBool: false;
				default: true;
			}))
				fail("E1011", 'Abstract comparison operator "$symbol" must return Bool', selected.method.span);
		var arguments = [
			for (index in 0...operands.length)
				bodyTyper.coerce(operands[index], selected.expected[index], "abstract operator", "E1010")
		];
		session.invalidateCallEffects(selected.key, scope);
		return new TypedExpression(TCall(selected.key, arguments), resultType, span);
	}

	/** `value.match(pattern)` on an enum value. */
	public function isEnumMatch(receiver:TypedExpression, name:String, arguments:Array<AstExpression>):Bool
		return name == "match" && arguments.length == 1 && switch receiver.type {
			case TInstance(NominalKind.Enum, _, _): true;
			default: false;
		};

	/**
	 * Whether `object` matches `pattern`: `switch object { case pattern: true; default: false }`, with `object` evaluated once.
	 * As in Haxe, the pattern binds no names.
	 */
	public function typeEnumMatch(object:AstExpression, pattern:AstExpression, span:SourceSpan,
			scope:Scope):TypedExpression {
		var matched = new TemporaryLocal("__haxeon_match" + span.start),
			patterns = session.currentContext.postfixMatchPatterns;
		var cases:Array<AstSwitchExpressionCase> = [
			{
				patterns: compiler.syntax.Parser.expandPatternAlternatives(pattern),
				guard: null,
				result: BoolLiteral(true, span),
				span: span
			}
		];
		patterns.push(compiler.syntax.Parser.expressionSpan(pattern));
		try {
			var typed = bodyTyper.typeExpression(BlockExpression([TemporaryDeclaration(matched, null, object, span)],
				SwitchExpression(TemporaryVariable(matched, span), cases, BoolLiteral(false, span), span), span),
				scope);
			patterns.pop();
			return typed;
		} catch (error:haxe.Exception) {
			patterns.pop();
			throw error;
		}
	}

	/**
	 * `receiver.name(arguments)`: a member of the receiver's type, else a static extension (`StaticExtensions`), tried only once
	 * the type has no member `name`, as in Haxe. `declaredReceiver` is the receiver as written when its type is nullable
	 * (`receiver` is then its value): an extension whose first argument accepts null is passed it, null included.
	 */
	public function typeMethodCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, platformFirst:Bool = true, receiverName:Null<String> = null,
			contextualGenericArguments:Bool = true, ?declaredReceiver:TypedExpression):TypedExpression {
		try
			return typeMemberCall(receiver, name, arguments, span, scope, expectedType, platformFirst, receiverName,
				contextualGenericArguments)
		catch (missing:MissingMember) {
			// Only this call's own member is missing (not one called among its arguments), and only a value takes an extension:
			// `Class.name()` names a static, as Haxe's `using` applies to values.
			if (missing.span != span || receiver.expression.match(TClassRef(_)))
				throw missing;
			var extension = typeStaticExtensionCall(declaredReceiver == null ? receiver : declaredReceiver, receiver,
				name,
				arguments, span, scope, expectedType);
			if (extension == null)
				throw missing;
			return extension;
		}
	}

	/**
	 * The call of the static extension `name` on `receiver` (`using`, `@:using`), as `Owner.name(receiver, arguments)`, or null
	 * when none applies. `declared` is the receiver as written, `receiver` its non-null value: the extension is passed the first
	 * when its first argument accepts null.
	 */
	function typeStaticExtensionCall(declared:TypedExpression, receiver:TypedExpression, name:String,
			arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):Null<TypedExpression> {
		var extension = staticExtensions.find(declared.type, name, span);
		if (extension == null && declared != receiver)
			extension = staticExtensions.find(receiver.type, name, span);
		if (extension == null)
			return null;
		var fn = extension.fn, key = extension.key;
		if (fn == null) {
			var expected = key == "Type.enumEq" ? 1 : 0;
			if (arguments.length != expected)
				fail("E1008",
					'Function "haxe.EnumTools.EnumValueTools.$name" expects $expected arguments, got ${arguments.length}',
					span);
			return typeEnumValueFunction(key, key == "Type.enumEq" ? declared : receiver, arguments, span, scope);
		}
		if (extension.owner.kind != ModuleFunctions)
			MemberAccess.method(session, extension.owner.name, name, span);
		if (arguments.length + 1 > fn.arguments.length
			&& !RestArguments.isRest(fn.arguments[fn.arguments.length - 1].type))
			fail("E1008", 'Function "$key" expects ${fn.arguments.length - 1} arguments, got ${arguments.length}',
				span);
		var parameters = BodyTyper.functionTypeParameters(fn);
		if (parameters.length > 0) {
			var first = receiverFor(declared, receiver, null), preset:Map<String, CompilerType> = [];
			// A Void expectation is a statement whose result is discarded, not a result of type Void.
			if (expectedType != null && !sameType(expectedType, TVoid))
				genericInstantiation.inferTypeParameters(fn.result, expectedType, parameters, preset, span);
			var prepared = typeGenericCallArguments(fn, arguments, scope, span, [first], preset);
			var info = session.methodInfo.get(key);
			return genericInstantiation.specialize(key, fn, prepared.arguments, span, scope,
				info == null ? null : info.owner, true, prepared.substitutions);
		}
		var first = receiverFor(declared, receiver, bodyTyper.argumentTypesOf(fn, [])[0]),
			typed = typeDeclaredCallArguments(arguments, fn, scope, key, span, null, false, first);
		return applyCallEffect(new TypedExpression(session.cNativeFunctions.exists(key) ? TCNativeCall(key,
			typed) : TCall(key, typed), bodyTyper.functionResultType(fn, fn.span), span), key, scope);
	}

	/**
	 * `receiver.name` read as a value where the receiver's type has no member `name`: the static extension `Owner.name` with the
	 * receiver bound as its first argument, as Haxe makes it (`var trim = text.trim;`), or null when no extension applies. The
	 * receiver is evaluated once, where it is read; the value is a function of the extension's other arguments. A generic
	 * extension takes its type arguments from the receiver.
	 */
	public function boundStaticExtension(receiver:TypedExpression, name:String, span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		if (receiver.expression.match(TClassRef(_)))
			return null;
		var value = unwrapNullable(receiver), extension = staticExtensions.find(receiver.type, name, span);
		if (extension == null && value != receiver)
			extension = staticExtensions.find(value.type, name, span);
		if (extension == null)
			return null;
		var fn = extension.fn;
		if (fn == null)
			return boundEnumValueFunction(value, extension.key, name, span, scope);
		if (extension.owner.kind != ModuleFunctions)
			MemberAccess.method(session, extension.owner.name, name, span);
		var parameters = BodyTyper.functionTypeParameters(fn), substitutions:Map<String, CompilerType> = [];
		if (parameters.length > 0) {
			genericInstantiation.inferArgumentTypeParameters(fn, 0, fn.arguments[0], value.type, parameters,
				substitutions, span);
			for (parameter in parameters)
				if (!substitutions.exists(parameter))
					fail("E1003",
						'Cannot infer the type parameter "$parameter" of "${extension.key}" from the value it is read on; call it instead',
						span);
		}
		var types = bodyTyper.argumentTypesOf(fn, substitutions),
			result = parameters.length == 0 ? bodyTyper.functionResultType(fn,
				fn.span) : session.declarations.types.resultType(fn,
				substitutions),
			held = new TemporaryLocal("__haxeon_bound" + span.start),
			inner = new Scope(scope),
			arguments:Array<AstArgument> = [],
			passed:Array<AstExpression> = [TemporaryVariable(held, span)];
		var heldBinding = inner.define(held.name, value.type, span, true, null, false, null, null, held);
		bodyTyper.bindCell(heldBinding, value.type);
		for (index in 1...fn.arguments.length) {
			var argument = new TemporaryLocal("__haxeon_argument" + index);
			arguments.push({
				name: argument.name,
				type: InferredType,
				span: span,
				optional: AstPredicates.isOptionalArgument(fn.arguments[index]),
				local: argument
			});
			passed.push(RestArguments.isRest(fn.arguments[index].type) ? Spread(TemporaryVariable(argument, span),
				span) : TemporaryVariable(argument, span));
		}
		// A plain extension is called through its value, whose dispatch entry gives an omitted argument its default.
		var expected = TFunction([
			for (index in 1...types.length)
				DefaultArguments.dispatchType(fn.arguments[index], types[index], session.relations)
		], result, FunctionTypes.ofArguments(arguments)),
			call = parameters.length == 0 ? ClosureCall(Variable(extension.key, span), passed,
				span) : Call(extension.key,
				passed, span),
			bound = bodyTyper.typeExpression(Lambda(arguments, [switch result {
				case TVoid: Expression(call, span);
				default: Return(call, span);
			}], 'bound:$name@${span.start}', span), inner, expected);
		return new TypedExpression(TBlockExpression([TVar(heldBinding.id, value, span)], bound), bound.type,
			span);
	}

	/**
	 * The `Type` function `name` (`Type.enumConstructor`, `Type.enumParameters`, `Type.enumIndex`, `Type.enumEq`) on the typed
	 * enum value `value`, with the call's other arguments: what a call of it and Haxe's `EnumValueTools` extension both type.
	 */
	function typeEnumValueFunction(name:String, value:TypedExpression, others:Array<AstExpression>, span:SourceSpan,
			scope:Scope):TypedExpression {
		var expected = name == "Type.enumEq" ? 1 : 0;
		if (others.length != expected)
			fail("E1008", 'Function "$name" expects ${expected + 1} arguments, got ${others.length + 1}', span);
		if (name == "Type.enumEq")
			return typeEnumEq(value, others[0], scope, span);
		var type = EnumReflection.enumType(value.type);
		if (type == null)
			throw new CompileError(new Diagnostic("E1009", '$name requires an enum value', span));
		value = bodyTyper.coerce(value, type, '$name value', "E1002");
		return switch name {
			case "Type.enumConstructor": EnumReflection.constructorName(session, bodyTyper, value, scope, span);
			case "Type.enumParameters": EnumReflection.parameters(session, bodyTyper, value, scope, span);
			case "Type.enumIndex": new TypedExpression(TEnumIndex(value), TInt, span);
			default: throw new InternalError('Unknown enum value function "$name"');
		};
	}

	/**
	 * `Type.enumEq(left, right)`: an enum value's constructors and arguments compared deeply, through its reflective equality;
	 * on `Dynamic` values, through the concrete enum each holds.
	 */
	function typeEnumEq(leftValue:TypedExpression, rightExpression:AstExpression, scope:Scope,
			span:SourceSpan):TypedExpression {
		var rightValue = bodyTyper.typeExpression(rightExpression, scope, leftValue.type);
		if (EnumReflection.enumType(leftValue.type) != null) {
			EnumEqualityGenerator.requestReflective(session, leftValue.type, session.currentContext.name, span);
			return new TypedExpression(TCall(EnumEqualityGenerator.reflectiveName(leftValue.type),
				[
					leftValue,
					bodyTyper.coerce(rightValue, leftValue.type, "Type.enumEq value", "E1002")
				]),
				TBool, span);
		}
		var left = bodyTyper.coerce(leftValue, TDynamic, "Type.enumEq value", "E1002"),
			right = bodyTyper.coerce(rightValue, TDynamic, "Type.enumEq value", "E1002");
		return new TypedExpression(TCall("$enum-dynamic-reflect", [left, right]), TBool, span);
	}

	/**
	 * Haxe's `EnumValueTools.name` read as a value (`var name = color.getName;`): a function of its other arguments with the
	 * enum value `value` bound, evaluated where it is read, as `boundStaticExtension` makes an extension's.
	 */
	function boundEnumValueFunction(value:TypedExpression, typeFunction:String, name:String, span:SourceSpan,
			scope:Scope):TypedExpression {
		var held = new TemporaryLocal("__haxeon_bound" + span.start),
			inner = new Scope(scope),
			arguments:Array<AstArgument> = [],
			argumentTypes:Array<CompilerType> = [],
			passed:Array<AstExpression> = [TemporaryVariable(held, span)];
		var heldBinding = inner.define(held.name, value.type, span, true, null, false, null, null, held);
		bodyTyper.bindCell(heldBinding, value.type);
		if (typeFunction == "Type.enumEq") {
			var argument = new TemporaryLocal("__haxeon_argument1");
			arguments.push({name: argument.name, type: InferredType, span: span, optional: false, local: argument});
			argumentTypes.push(value.type);
			passed.push(TemporaryVariable(argument, span));
		}
		var result = switch typeFunction {
			case "Type.enumConstructor": TString;
			case "Type.enumParameters": TArray(TDynamic);
			case "Type.enumIndex": TInt;
			default: TBool;
		},
			bound = bodyTyper.typeExpression(Lambda(arguments, [Return(Call(typeFunction, passed, span), span)],
			'bound:$name@${span.start}', span), inner,
			TFunction(argumentTypes, result, FunctionTypes.ofArguments(arguments)));
		return new TypedExpression(TBlockExpression([TVar(heldBinding.id, value, span)], bound), bound.type,
			span);
	}

	/**
	 * The receiver an extension is passed: as written where the first argument takes null (`Null<T>`, `Dynamic`, or a generic
	 * one, whose type the receiver fixes), else its non-null value, as a member call reads it.
	 */
	function receiverFor(declared:TypedExpression, receiver:TypedExpression,
			first:Null<CompilerType>):TypedExpression {
		if (declared == receiver)
			return receiver;
		if (first == null)
			return declared;
		return switch first {
			case TNullable(_), TDynamic, TNull: declared;
			default: receiver;
		};
	}

	function typeMemberCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, platformFirst:Bool, receiverName:Null<String>,
			contextualGenericArguments:Bool):TypedExpression {
		var synthesized = TypeParameterMembers.synthesizedMember(session, receiver, name);
		if (synthesized != null) {
			if (arguments.length != synthesized.arguments.length)
				fail("E1008", '$name expects ${synthesized.arguments.length} arguments, got ${arguments.length}', span);
			typeCallArguments(arguments, synthesized.arguments, scope, name);
			return new TypedExpression(TCast(receiver), synthesized.result, span);
		}
		receiver = TypeParameterMembers.receiver(session, bodyTyper, receiver, name, span);
		var pathCall = KeyPathOperations.call(session, receiver, name, arguments, span, scope, bodyTyper);
		if (pathCall != null)
			return pathCall;
		if (isRawPointerType(receiver.type)) {
			var rawPointerCall = typeRawPointerMethod(receiver, name, arguments, span, scope, expectedType);
			if (rawPointerCall != null)
				return rawPointerCall;
		}
		var platformMethod = PlatformAbi.method(receiver.type, name);
		if (platformFirst && platformMethod != null) {
			var typed = typeCallArguments(arguments, platformMethod.arguments, scope, name);
			var module = PlatformAbi.sourceModule(platformMethod.nativeName);
			if (module != null)
				session.runtimeDependencyTracker.record(session.currentContext.name, module);
			return new TypedExpression(TCall(platformMethod.nativeName, [receiver].concat(typed)),
				platformMethod.result, span);
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
			var module = PlatformAbi.sourceModule(platformMethod.nativeName);
			if (module != null)
				session.runtimeDependencyTracker.record(session.currentContext.name, module);
			return new TypedExpression(TCall(platformMethod.nativeName, [receiver].concat(typed)),
				platformMethod.result, span);
		}
		var forwardedArray = AbstractForwarding.arrayStorage(session, receiver.type, name);
		if (forwardedArray != null)
			return typeArrayMethod(session.representation.boundaryCast(receiver, forwardedArray), name, arguments, span,
				scope);
		var abstractCall = typeAbstractMethodCall(receiver, name, arguments, span, scope);
		if (abstractCall != null)
			return abstractCall;
		var fieldCall = typeFunctionFieldCall(receiver, name, arguments, span, scope);
		if (fieldCall != null)
			return fieldCall;
		return resolveInstanceMethod(receiver, name, arguments, span, scope, expectedType, receiverName,
			contextualGenericArguments);
	}

	public function typeRawPointerNullCall(name:String, arguments:Array<AstExpression>, span:SourceSpan,
			expectedType:Null<CompilerType>):Null<TypedExpression> {
		if (name != "RawPtr.nullPtr" && !StringTools.endsWith(name, ".RawPtr.nullPtr"))
			return null;
		if (arguments.length != 0)
			fail("E1008", 'RawPtr.nullPtr expects no arguments, got ${arguments.length}', span);
		return switch expectedType {
			case TAbstract(declaration, typeArguments,
				_) if (isRawPointerAbstract(declaration) && typeArguments.length == 1):
				new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), expectedType, span);
			case _:
				fail("E1009", "RawPtr.nullPtr needs an expected RawPtr<T> type", span);
				null;
		};
	}

	static function isFloatingMapKey(type:CompilerType):Bool
		return switch type {
			case TAbstract(_, _, representation), TNullable(representation): isFloatingMapKey(representation);
			case TFloat, TNativeScalar("f32" | "f64"): true;
			default: false;
		};

	function typeRawPointerMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope,
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
				return rawPointerAccess("load", [receiver], span);
			case "store":
				if (arguments.length != 1)
					fail("E1008", "RawPtr.store expects one value", span);
				if (NativeLayout.isNativeValue(pointee))
					fail("E1022", "Native records are address-only and cannot be stored by value", span);
				if (flatValueRecordName(pointee) == null && !TypeRepresentation.mentionsTypeParameter(pointee))
					nativeMemoryLayout(pointee, span);
				var value = bodyTyper.coerce(bodyTyper.typeExpression(arguments[0], scope, pointee), pointee,
					"RawPtr.store value", "E1002");
				return rawPointerAccess("store", [receiver, value], span);
			case "offset":
				if (arguments.length != 1)
					fail("E1008", "RawPtr.offset expects one element count", span);
				if (!TypeRepresentation.mentionsTypeParameter(pointee))
					nativePointerStride(pointee, span);
				var count = bodyTyper.coerce(bodyTyper.typeExpression(arguments[0], scope, TInt), TInt,
					"RawPtr.offset count", "E1002");
				return rawPointerAccess("offset", [receiver, count], span);
			case "byteOffset":
				if (arguments.length != 1)
					fail("E1008", "RawPtr.byteOffset expects one byte count", span);
				var count = bodyTyper.coerce(bodyTyper.typeExpression(arguments[0], scope, TInt), TInt,
					"RawPtr.byteOffset count",
					"E1002");
				return new TypedExpression(TCall("$rawptr.byteOffset", [receiver, count]), receiver.type, span);
			case "castTo":
				if (arguments.length != 0)
					fail("E1008", "RawPtr.castTo expects no arguments", span);
				return switch expectedType {
					case TAbstract(declaration, castArguments,
						_) if (isRawPointerAbstract(declaration) && castArguments.length == 1):
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
		// A type parameter's layout is its specialization's. A body is typed with its parameters as themselves only to be checked
		// (an abstract's member nothing calls), and the code of no specialization comes from it.
		if (type.match(TTypeParameter(_, _)))
			return {size: 0, signed: false};
		if (NativeLayout.isNativeValue(type)) {
			var name = switch type {
				case TInstance(NominalKind.NativeValue, name, _): name;
				case _: throw new InternalError("Native value type check lost its nominal type");
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

	function flatValueRecordName(type:CompilerType):Null<String>
		return switch type {
			case TInstance(NominalKind.Class, name, []) if (session.nativeLayoutsByName.exists(name)): name;
			case _: null;
		};

	function nativePointerStride(type:CompilerType, span:SourceSpan):Int {
		var name = flatValueRecordName(type);
		if (name != null) {
			var layout = session.nativeLayoutsByName.get(name);
			if (layout == null)
				fail("E1022", 'Flat value "$name" has no layout for ABI target "${session.nativeAbiTarget}"', span);
			return layout.size;
		}
		if ((switch (type) {
			case TDynamic: true;
			default: false;
		})) {
			var context = session.currentContext,
				substitutions = [
					for (parameter in context.typeSubstitutions.keys())
						'$parameter=${Std.string(context.typeSubstitutions.get(parameter))}'
				].join(", ");
			fail("E1022",
				'RawPtr.offset needs a concrete element layout, got Dynamic while typing "${context.functionName}" (substitutions: [$substitutions])',
				span);
		}
		return nativeMemoryLayout(type, span).size;
	}

	static function isRawPointerType(type:CompilerType):Bool
		return switch type {
			case TAbstract(name, _, _) if (isRawPointerAbstract(name)): true;
			case _: false;
		};

	static function isRawPointerAbstract(declaration:String):Bool
		return declaration == "RawPtr" || StringTools.endsWith(declaration, ".RawPtr");

	function typeExpressionValue(expression:AstExpression, scope:Scope, ?expectedType:CompilerType):TypedExpression
		return bodyTyper.typeExpression(expression, scope, expectedType);

	/**
		Types a call's arguments against the callee's declared parameters, filling omitted ones. A virtual call
		(`virtualCall`) reaches the method's dispatch entry: it passes `Null<T>` for an argument with a value default, and
		null for an omitted argument the method that runs fills itself (`DefaultArguments`).
	**/
	public function typeDeclaredCallArguments(arguments:Array<AstExpression>, callee:AstFunction,
			scope:Scope, name:String, span:SourceSpan,
			?substitutions:Map<String, CompilerType>, virtualCall:Bool = false,
			?leading:TypedExpression):Array<TypedExpression> {
		// `leading` is a first argument typed already: a static extension's receiver.
		var offset = leading == null ? 0 : 1;
		arguments = RestArguments.pack(callee.arguments, arguments, offset, span);
		var parameters = callee.arguments,
			declared = bodyTyper.argumentTypesOf(callee, substitutions),
			required = parameters.length;
		while (required > offset && AstPredicates.isOptionalArgument(parameters[required - 1]))
			required--;
		if (arguments.length + offset < required || arguments.length + offset > parameters.length) {
			var expected = required == parameters.length
				? '${required - offset}' : '${required - offset} to ${parameters.length - offset}';
			fail("E1008", 'Function "$name" expects $expected arguments, got ${arguments.length}', span);
		}
		var typed:Array<TypedExpression> = [],
			types = [
				for (index in 0...parameters.length)
					virtualCall ? DefaultArguments.dispatchType(parameters[index], declared[index],
					session.relations) : declared[index]
			];
		if (leading != null)
			typed.push(bodyTyper.coerce(leading, types[0], 'argument 1 to "$name"'));
		for (i in 0...arguments.length) {
			var supplied = types[i + offset],
				value = bodyTyper.typeExpression(arguments[i], scope, supplied);
			typed.push(bodyTyper.coerce(value, supplied, 'argument ${i + 1 + offset} to "$name"'));
		}
		for (i in arguments.length + offset...parameters.length) {
			var parameter = parameters[i],
				expected = types[i],
				defaultValue = parameter.defaultValue;
			if (isPosInfosParameter(parameter))
				typed.push(bodyTyper.coerce(bodyTyper.typeExpression(bodyTyper.posInfosExpression(span), scope,
					expected), expected,
					'position argument ${i + 1} to "$name"'));
			else if (defaultValue == null || virtualCall && (DefaultArguments.filledByCallee(parameter, expected,
				session.relations) || DefaultArguments.valueDefault(parameter, declared[i], session.relations)))
				typed.push(bodyTyper.coerce(new TypedExpression(TNullLiteral, TNull, span), expected,
					'default argument ${i + 1} to "$name"'));
			else
				typed.push(bodyTyper.coerce(bodyTyper.typeDefaultExpression(parameter, expected, name), expected,
					'default argument ${i + 1} to "$name"'));
		}
		return coerceArguments(typed, types, name);
	}

	/**
		Types a generic call's arguments while inferring its type parameters.
		`leading` holds arguments that are already typed, such as the receiver
		of an array method implemented as a library function. Lambda literals
		are typed after the other arguments, so `values.map(x -> x * 2)` learns
		`x : Int` from `values`; a type parameter that only the lambda's result
		can decide (`S` in `map<T, S>(values:Array<T>, f:T->S)`) is inferred from
		the lambda body.
	**/
	public function typeGenericCallArguments(fn:AstFunction, arguments:Array<AstExpression>, scope:Scope,
			span:SourceSpan, ?leading:Array<TypedExpression>,
			?presetSubstitutions:Map<String, CompilerType>):{
				arguments:Array<TypedExpression>,
				substitutions:Map<String, CompilerType>
			} {
		return typeGenericArguments(BodyTyper.functionTypeParameters(fn), fn.arguments, arguments, scope, span, leading,
			presetSubstitutions, fn);
	}

	/**
		`typeGenericCallArguments` for any callee whose `declaredArguments` mention the type parameters `parameters`: a
		generic function, or a generic enum's constructor (`typeEnumConstructor`).
	**/
	function typeGenericArguments(parameters:Array<String>, declaredArguments:Array<AstArgument>,
			arguments:Array<AstExpression>, scope:Scope, span:SourceSpan, ?leading:Array<TypedExpression>,
			?presetSubstitutions:Map<String, CompilerType>, ?fn:AstFunction):{
				arguments:Array<TypedExpression>,
				substitutions:Map<String, CompilerType>
			} {
		arguments = RestArguments.pack(declaredArguments, arguments, leading == null ? 0 : leading.length, span);
		var substitutions:Map<String, CompilerType> = presetSubstitutions == null ? [] : copyMap(presetSubstitutions),
			typed:Array<Null<TypedExpression>> = [],
			offset = leading == null ? 0 : leading.length,
			lambdas:Array<Int> = [];
		// A parameter a `Dynamic` expectation of the result gives (`trace(one(i -> p))`) is what the arguments leave it: Dynamic
		// only where they fix nothing, as Haxe's Dynamic unifies with any type.
		var fallbacks = [for (parameter => type in substitutions) if (type.match(TDynamic)) parameter];
		for (parameter in fallbacks)
			substitutions.remove(parameter);
		function settleFallbacks():Bool {
			var settled = false;
			for (parameter in fallbacks)
				if (!substitutions.exists(parameter)) {
					substitutions.set(parameter, TDynamic);
					settled = true;
				} else if (compiler.types.Monomorphs.isUnbound(requiredMapValue(substitutions, parameter)))
					compiler.types.Monomorphs.unify(requiredMapValue(substitutions, parameter), TDynamic);
			return settled;
		}
		if (leading != null)
			for (index in 0...leading.length) {
				genericInstantiation.inferArgumentTypeParameters(fn, index, declaredArguments[index],
					leading[index].type,
					parameters, substitutions, leading[index].span);
				typed.push(leading[index]);
			}
		for (index in 0...arguments.length) {
			if (isLambdaLiteral(arguments[index])) {
				lambdas.push(index);
				typed.push(null);
				continue;
			}
			var declared = declaredArguments[offset + index],
				expected:Null<CompilerType> = null;
			if (allTypeParametersBound(parameters, substitutions))
				expected = genericInstantiation.expectedArgumentType(fn, offset + index, declared, substitutions);
			var argument = bodyTyper.typeExpression(arguments[index], scope, expected, expected != null);
			genericInstantiation.inferArgumentTypeParameters(fn, offset + index, declared, argument.type, parameters,
				substitutions, argument.span);
			typed.push(argument);
		}
		while (lambdas.length > 0) {
			var progressed = false;
			for (index in lambdas.copy()) {
				var declared = declaredArguments[offset + index],
					opened:Map<String, CompilerType> = [],
					expected = lambdaExpectation(declared.type, declared.span,
						compiler.syntax.Parser.expressionSpan(arguments[index]), parameters, substitutions, opened,
						fallbacks);
				if (expected == null && !lambdaParametersAnnotated(arguments[index]))
					continue;
				var argument = bodyTyper.typeExpression(arguments[index], scope, expected, expected != null);
				genericInstantiation.inferArgumentTypeParameters(fn, offset + index, declared, argument.type,
					parameters,
					substitutions, argument.span);
				// A parameter only the callback's result fixes is the type variable its body filled (or left empty, which
				// `settleTypeArguments` settles where only this callback carries it).
				for (parameter => variable in opened)
					if (!substitutions.exists(parameter))
						substitutions.set(parameter, variable);
				typed[offset + index] = argument;
				lambdas.remove(index);
				progressed = true;
			}
			if (!progressed && !settleFallbacks()) {
				// No callback supplies the missing parameter context. Preserve the
				// ordinary inference diagnostic rather than assuming Dynamic.
				var index = lambdas[0];
				bodyTyper.typeExpression(arguments[index], scope);
				fail("E1003", "Cannot infer generic callback context", span);
			}
		}
		settleFallbacks();
		return {arguments: [for (argument in typed) requiredArgument(argument)], substitutions: substitutions};
	}

	static function requiredArgument(argument:Null<TypedExpression>):TypedExpression {
		if (argument == null)
			throw new InternalError("Generic call argument was not typed");
		return argument;
	}

	static function lambdaParametersAnnotated(expression:AstExpression):Bool
		return switch LambdaSyntax.literal(expression) {
			case Lambda(arguments, _, _, _):
				var annotated = true;
				for (argument in arguments)
					if ((switch (argument.type) {
						case InferredType: true;
						default: false;
					}))
						annotated = false;
				annotated;
			default:
				false;
		};

	static function isLambdaLiteral(expression:AstExpression):Bool
		return switch LambdaSyntax.literal(expression) {
			case Lambda(_, _, _, _): true;
			default: false;
		};

	/**
		The function type a lambda argument (written at `argumentSpan`) is typed against. Its parameter types
		must be known; a result that still mentions an unbound type parameter opens a type variable for it
		(`openResult`), recorded in `opened`, which the lambda's body fills; `fallbacks` are the parameters a Dynamic
		expectation of the call's result gives.
	**/
	function lambdaExpectation(declared:AstType, span:SourceSpan, argumentSpan:SourceSpan, parameters:Array<String>,
			substitutions:Map<String, CompilerType>, opened:Map<String, CompilerType>,
			fallbacks:Array<String>):Null<CompilerType> {
		if (allTypeParametersBound(parameters, substitutions))
			return session.declarations.resolve(declared, span, substitutions);
		return switch declared {
			case FunctionType(arguments, result, optional):
				for (argument in arguments)
					if (mentionsUnbound(argument, parameters, substitutions))
						return null;
				var resolvedArguments = [
					for (argument in arguments)
						session.declarations.resolve(argument, span, substitutions)
				];
				CompilerType.TFunction(resolvedArguments,
					mentionsUnbound(result, parameters, substitutions) ? openResult(result, span, argumentSpan,
					parameters, substitutions, opened, fallbacks) : session.declarations.resolve(result, span,
					substitutions),
					FunctionTypes.canonical(optional));
			default: null;
		};
	}

	/**
	 * A callback's expected result that mentions type parameters nothing has fixed yet (`f:T->Iterable<S>`): each is a type variable
	 * the callback's result fills, as in Haxe, so its body converts to the declared result (an Array to `Iterable<S>`) and the call
	 * infers the parameter from it. Each variable is made at the callback (`argumentSpan`), which carries it, and recorded in `opened`.
	 * Dynamic where no body is being typed, which could settle the variables.
	 */
	function openResult(result:AstType, span:SourceSpan, argumentSpan:SourceSpan, parameters:Array<String>,
			substitutions:Map<String, CompilerType>, opened:Map<String, CompilerType>,
			fallbacks:Array<String>):CompilerType {
		var open = copyMap(substitutions), made:Map<String, CompilerType> = [];
		for (parameter in parameters)
			if (!open.exists(parameter)) {
				var variable = session.monomorphs.create('the type parameter "$parameter" of a callback\'s result',
					argumentSpan);
				if (variable == null)
					return TDynamic;
				open.set(parameter, variable);
				made.set(parameter, variable);
			}
		var resolved = session.declarations.resolve(result, span, open);
		// A recursive typedef's structure is named after its type arguments when it is resolved (`Node<T>`), so one resolved
		// while a variable is empty keeps that variable's spelling in its name, and two callbacks would share it: Dynamic, as
		// before results were opened.
		if (namesEmptyVariable(resolved, [])) {
			// Where the call's result is expected as Dynamic, the parameters are Dynamic, as that expectation gives them.
			for (parameter in made.keys())
				if (fallbacks.indexOf(parameter) < 0)
					return TDynamic;
			for (parameter in made.keys()) {
				open.set(parameter, TDynamic);
				opened.set(parameter, TDynamic);
			}
			return session.declarations.resolve(result, span, open);
		}
		for (parameter => variable in made)
			opened.set(parameter, variable);
		return resolved;
	}

	/** Whether `type` holds a recursive structure named while a type variable it mentions was empty. */
	static function namesEmptyVariable(type:CompilerType, seen:Array<Array<compiler.types.Type.AnonymousField>>):Bool
		return switch type {
			case TAnonymous(name, fields):
				if (seen.indexOf(fields) >= 0)
					false;
				else if (SemanticSignature.isRecursiveAnonymousName(name) && name.indexOf("unknown:") >= 0)
					true;
				else {
					seen.push(fields);
					var found = false;
					for (field in fields)
						if (namesEmptyVariable(field.type, seen))
							found = true;
					found;
				}
			case TNullable(element), TArray(element), TIterator(element): namesEmptyVariable(element, seen);
			case TMap(key, value): namesEmptyVariable(key, seen) || namesEmptyVariable(value, seen);
			case TInstance(_, _, arguments), TAbstract(_, arguments, _):
				var found = false;
				for (argument in arguments)
					if (namesEmptyVariable(argument, seen))
						found = true;
				found;
			case TFunction(arguments, result, _):
				var found = namesEmptyVariable(result, seen);
				for (argument in arguments)
					if (namesEmptyVariable(argument, seen))
						found = true;
				found;
			default: false;
		};

	static function mentionsUnbound(type:AstType, parameters:Array<String>,
			substitutions:Map<String, CompilerType>):Bool
		return switch type {
			case NamedType(name): parameters.indexOf(name) >= 0 && !substitutions.exists(name);
			case AppliedType(_, arguments): anyMentionsUnbound(arguments, parameters, substitutions);
			case ArrayType(element), NullableType(element): mentionsUnbound(element, parameters, substitutions);
			case MapType(key, value): mentionsUnbound(key, parameters, substitutions)
				|| mentionsUnbound(value, parameters, substitutions);
			case FunctionType(arguments, result, _): mentionsUnbound(result, parameters,
				substitutions) || anyMentionsUnbound(arguments, parameters, substitutions);
			case AnonymousType(fields): anyMentionsUnbound([for (field in fields) field.type], parameters,
				substitutions);
			default: false;
		};

	static function anyMentionsUnbound(types:Array<AstType>, parameters:Array<String>,
			substitutions:Map<String, CompilerType>):Bool {
		for (type in types)
			if (mentionsUnbound(type, parameters, substitutions))
				return true;
		return false;
	}

	public function findMethod(className:String, name:String):Null<SemanticMethodInfo>
		return MemberAccess.methodInfo(session, className, name);

	/**
	 * `dynamicValue.method(arguments)`: the method is looked up by name when the program runs and called with its
	 * arguments as Dynamic values, and what it returns is Dynamic. It may run any code, so nothing known about the
	 * captured variables or fields survives it, as for a call through a function value of unknown body.
	 */
	function resolveDynamicMethodCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope):TypedExpression {
		session.runtimeDependencyTracker.record(session.currentContext.name, "Reflect");
		var callee = new TypedExpression(TCall("Reflect.field", [
			receiver,
			new TypedExpression(TStringLiteral(name), TString, span)
		]), TDynamic, span),
			typedArguments = [
				for (argument in arguments)
					bodyTyper.coerce(bodyTyper.typeExpression(argument, scope, TDynamic), TDynamic,
					'argument to dynamic method "$name"')
			];
		session.invalidateUnknownCall(scope);
		return new TypedExpression(TClosureCall(callee, typedArguments), TDynamic, span);
	}

	public function resolveInstanceMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, receiverName:Null<String> = null,
			contextualGenericArguments:Bool = true):TypedExpression {
		if (sameType(receiver.type, TDynamic)) {
			// A Dynamic value takes an extension whose first argument is Dynamic before its field is looked up at run time.
			var extension = typeStaticExtensionCall(receiver, receiver, name, arguments, span, scope, expectedType);
			return extension != null ? extension : resolveDynamicMethodCall(receiver, name, arguments, span, scope);
		}
		var enumMethod = EnumConformanceMethods.method(session, receiver.type, name);
		if (enumMethod != null) {
			if (name == "equals") {
				if (arguments.length != 1)
					fail("E1008", 'Method "equals" expects 1 argument, got ${arguments.length}', span);
				var other = bodyTyper.coerce(bodyTyper.typeExpression(arguments[0], scope, receiver.type),
					receiver.type,
					"enum equality operand");
				var keyed = EnumEqualityGenerator.request(session, receiver.type, session.currentContext.name, span);
				session.invalidateUnknownCall(scope);
				return new TypedExpression(TCall(EnumEqualityGenerator.equalsName(keyed), [receiver, other]),
					TBool, span);
			}
			if (name == "hash") {
				if (arguments.length != 0)
					fail("E1008", 'Method "hash" expects 0 arguments, got ${arguments.length}', span);
				var keyed = HashGenerator.request(session, receiver.type, session.currentContext.name, span);
				session.invalidateUnknownCall(scope);
				return new TypedExpression(TCall(HashGenerator.hashName(keyed), [receiver]), TInt, span);
			}
			var substitutions:Map<String, CompilerType> = [];
			switch receiver.type {
				case TInstance(NominalKind.Enum, owner, typeArguments):
					var declaration = session.enumDecls.get(owner);
					if (declaration == null)
						throw new InternalError('Missing enum declaration "$owner"');
					for (index in 0...declaration.typeParameters.length)
						substitutions.set(declaration.typeParameters[index],
							index < typeArguments.length ? typeArguments[index] : TTypeParameter(owner,
							declaration.typeParameters[index]));
				default:
					throw new InternalError("Enum method without an enum receiver");
			}
			var typed = typeDeclaredCallArguments(arguments, enumMethod, scope, name, span, substitutions);
			var result = session.declarations.types.resultType(enumMethod, substitutions);
			var keyed = EnumConformanceMethods.request(session, receiver.type, name, session.currentContext.name, span);
			session.invalidateUnknownCall(scope);
			return new TypedExpression(TCall(EnumConformanceMethods.name(keyed, name),
				[receiver].concat(typed)), result, span);
		}
		var className = switch receiver.type {
			case TInstance(Class, value, _), TInstance(Interface, value, _):
				value;
			default:
				null;
		};
		if (className == null)
			throw new MissingMember("E1007",
				'Cannot call method on non-object "${receiverName == null ? name : receiverName}"', span);
		var methodInfo = findMethod(className, name);
		var classReference = switch receiver.expression {
			case TClassRef(_):
				true;
			default:
				false;
		};
		if (classReference && methodInfo != null && methodInfo.isStatic) {
			var methodKey = methodInfo.owner + "." + name,
				method = session.signatures.get(methodKey);
			if (method == null)
				fail("E1007", 'Missing signature for method "$methodKey"', span);
			MemberAccess.method(session, methodInfo.owner, name, span);
			if (BodyTyper.functionTypeParameters(method).length > 0) {
				var prepared = typeGenericCallArguments(method, arguments, scope, span);
				return genericInstantiation.specialize(methodKey, method, prepared.arguments, span, scope,
					methodInfo.owner, true, prepared.substitutions);
			}
			var typed = typeDeclaredCallArguments(arguments, method, scope, methodKey, span);
			return applyCallEffect(new TypedExpression(TCall(methodKey, typed),
				bodyTyper.functionResultType(method, method.span),
				span), methodKey, scope);
		}
		// A static field that holds a function (`static var build:Void->Int`) is called as its value is, as in Haxe: read the field,
		// then call what it holds, with the arity, optional arguments and effects of any function value.
		if (classReference && (methodInfo == null || !methodInfo.isStatic)) {
			var field = bodyTyper.findStaticFieldNullable(className, name);
			if (field != null) {
				var qualified = field.owner + "." + name;
				return typeClosureCall(Variable(qualified, span), arguments, span, scope, qualified);
			}
		}
		if (methodInfo == null || methodInfo.isStatic)
			throw new MissingMember("E1007", classReference
				? 'Unknown static method "$className.$name"' : 'Unknown instance method "$className.$name"', span);
		MemberAccess.method(session, methodInfo.owner, name, span);
		var methodOwnerType = projectNominal(receiver.type, methodInfo.owner),
			substitutions = session.representation.nominalSubstitutions(methodOwnerType),
			methodKey = methodInfo.owner + "." + name,
			method = session.signatures.get(methodKey);
		if (method == null)
			fail("E1007", 'Missing signature for method "$methodKey"', span);
		if (session.relations.isValueClass(receiver.type) && !session.isPureCall(methodKey)
			&& !session.isReadOnlyReceiver(methodKey))
			ValuePlaceRules.requireWritable(session, receiver, span);
		if (BodyTyper.functionTypeParameters(method).length > 0) {
			var preset = copyMap(substitutions),
				parameters = BodyTyper.functionTypeParameters(method);
			// A Void expectation is a statement whose result is discarded, not a result of type Void.
			if (expectedType != null && !sameType(expectedType, TVoid))
				genericInstantiation.inferTypeParameters(method.result, expectedType, parameters, preset, span);
			var prepared = typeGenericCallArguments(method, arguments, scope, span, null, preset);
			return genericInstantiation.specialize(methodKey, method, prepared.arguments, span, scope, methodInfo.owner,
				false, prepared.substitutions,
				receiver);
		}
		var semanticArguments = typeDeclaredCallArguments(arguments, method, scope, methodKey, span,
			substitutions, method.isExtern != true),
			physicalArguments = session.representation.adaptMethodArguments(methodOwnerType, methodInfo.owner, method,
				semanticArguments, method.isExtern != true),
			methodResult = session.representation.resolveMethodResult(methodOwnerType, methodInfo.owner, method),
			call = new TypedExpression(TMethodCall(receiver, methodKey, physicalArguments), methodResult.physical,
				span),
			castCall = session.representation.memberResultBoundary(call, methodResult, methodOwnerType,
				methodInfo.owner,
				method);
		if (scope != null)
			session.invalidateCallEffects(methodKey, scope);
		return session.isNoReturnCall(methodKey) ? new TypedExpression(TNoReturn(castCall), TNever,
			castCall.span) : castCall;
	}

	public function typeAbstractMethodCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		var abstractName:String, typeArguments:Array<CompilerType>;
		switch receiver.type {
			case TAbstract(name, arguments, _):
				abstractName = name;
				typeArguments = arguments;
			default:
				return null;
		}
		var rawDeclaration = session.enumAbstractDecls.get(abstractName);
		if (rawDeclaration != null && FlagsGenerator.conforms(session, rawDeclaration)
			&& FlagsGenerator.isMember(name, false)) {
			var info = FlagsGenerator.signature(abstractName, name),
				typed = typeCallArguments(arguments, info.arguments.slice(1), scope, name);
			return new TypedExpression(TCall(FlagsGenerator.request(session, abstractName, name, span),
				[receiver].concat(typed)), info.result, span);
		}

		if ((name == "rawValue" || name == "toString")
			&& rawDeclaration != null
			&& RawRepresentableGenerator.conforms(session, rawDeclaration)) {
			if (arguments.length != 0)
				fail("E1008", '$name expects no arguments', span);
			return new TypedExpression(TCall(RawRepresentableGenerator.request(session, abstractName, name, span),
				[receiver]),
				name == "toString" ? TString : bodyTyper.lowerType(rawDeclaration.underlying, rawDeclaration.span),
				span);
		}
		var declaration = session.declarations.abstractDeclaration(abstractName);
		if (declaration == null)
			throw new InternalError('Missing abstract declaration "$abstractName"');
		var method:Null<AstFunction> = null;
		for (candidate in declaration.methods)
			if (candidate.name == name && !candidate.isStatic && candidate.name != "new")
				method = candidate;
		if (method == null)
			throw new MissingMember("E1007", 'Unknown abstract method "$abstractName.$name"', span);
		MemberAccess.method(session, abstractName, name, span);
		var methodKey = abstractName + "." + name,
			signature = requiredMapValue(session.signatures, methodKey),
			substitutions = session.representation.typeParameterSubstitutions(declaration.typeParameters,
				typeArguments);
		if (declaration.isExtern == true || method.isExtern == true) {
			var typed = typeDeclaredCallArguments(arguments, signature, scope, methodKey, span,
				substitutions),
				callArguments:Array<TypedExpression> = [
					session.representation.boundaryCast(receiver,
						session.representation.semanticType(declaration.underlying, declaration.span, substitutions))
				];
			for (argument in typed)
				callArguments.push(argument);
			return new TypedExpression(TCall(methodKey, callArguments),
				session.declarations.types.resultType(signature, substitutions),
				span);
		}
		var typedArguments = [for (argument in arguments) bodyTyper.typeExpression(argument, scope)];
		return genericInstantiation.specialize(methodKey, signature, typedArguments, span, scope, abstractName, false,
			substitutions, receiver);
	}

	/**
	 * A call of the accessor `accessor` (`get_x`, `set_x`) of an abstract's property on `receiver`, a value of the abstract, with
	 * `arguments` typed already. The property's visibility was checked (`AbstractProperties.accessor`), not the accessor's. A
	 * `@:to` function, which the conversion calls wherever it is private, is called the same way.
	 */
	public function typeAbstractAccessorCall(receiver:TypedExpression, accessor:String,
			arguments:Array<TypedExpression>,
			span:SourceSpan, scope:Scope):TypedExpression {
		var abstractName:String, typeArguments:Array<CompilerType>;
		switch receiver.type {
			case TAbstract(name, arguments, _):
				abstractName = name;
				typeArguments = arguments;
			default:
				throw new InternalError('Accessor "$accessor" is called on a value of no abstract');
		}
		var declaration = session.declarations.abstractDeclaration(abstractName);
		if (declaration == null)
			throw new InternalError('Missing abstract declaration "$abstractName"');
		var methodKey = abstractName + "." + accessor,
			signature = requiredMapValue(session.signatures, methodKey),
			substitutions = session.representation.typeParameterSubstitutions(declaration.typeParameters,
				typeArguments);
		if (declaration.isExtern == true || signature.isExtern == true)
			return new TypedExpression(TCall(methodKey, [
				session.representation.boundaryCast(receiver,
					session.representation.semanticType(declaration.underlying, declaration.span, substitutions))
			].concat(arguments)), session.declarations.types.resultType(signature, substitutions), span);
		return genericInstantiation.specialize(methodKey, signature, arguments, span, scope, abstractName, false,
			substitutions, receiver);
	}

	public function typeFunctionFieldCall(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		var callableFieldType = bodyTyper.findFieldType(receiver.type, name);
		if (callableFieldType == null)
			return null;
		return switch callableFieldType {
			case TFunction(argumentTypes, result, _):
				if (arguments.length != argumentTypes.length)
					fail("E1008",
						'Function field "$name" expects ${argumentTypes.length} arguments, got ${arguments.length}',
						span);
				var typed = [
					for (index in 0...arguments.length)
						bodyTyper.typeExpression(arguments[index], scope, argumentTypes[index])
				];
				typed = coerceArguments(typed, argumentTypes, name);
				new TypedExpression(TClosureCall(bodyTyper.typedMember(receiver, name, span), typed), result, span);
			default:
				fail("E1007", 'Cannot call non-function field "$name"', span);
				null;
		};
	}

	public function typeImplicitFunctionFieldCall(name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		var thisType = scope.receiverType(),
			callableFieldType = thisType == null ? null : bodyTyper.findFieldType(thisType, name);
		if (callableFieldType == null) {
			// A static field of the class (or a base) that holds a function (`static var twice:Int->Int`), called by its bare name:
			// read the field, then call what it holds as any function value is called, as the qualified form `C.twice(4)` is.
			var owner = session.currentContext.lexicalOwner,
				staticField = owner == null ? null : bodyTyper.findStaticFieldNullable(owner, name);
			if (staticField == null)
				return null;
			var qualified = staticField.owner + "." + name;
			return typeClosureCall(Variable(qualified, span), arguments, span, scope, qualified);
		}
		var fieldCallable = typeExpressionValue(Variable(name, span), scope);
		return switch fieldCallable.type {
			case TFunction(argumentTypes, result, _):
				if (arguments.length != argumentTypes.length)
					fail("E1008",
						'Function field "$name" expects ${argumentTypes.length} arguments, got ${arguments.length}',
						span);
				var typed = [
					for (index in 0...arguments.length)
						bodyTyper.typeExpression(arguments[index], scope, argumentTypes[index])
				];
				typed = coerceArguments(typed, argumentTypes, name);
				new TypedExpression(TClosureCall(fieldCallable, typed), result, span);
			default:
				fail("E1007", 'Cannot call non-function field "$name"', span);
				null;
		};
	}

	/**
	 * `RawPtr.load`, `store` or `offset` (`name`) through `arguments[0]`, with the value or count after it. Where the pointee
	 * mentions a type parameter, its layout is the representation's: the elaboration pass makes the access
	 * (`rawPointerOperation`).
	 */
	function rawPointerAccess(name:String, arguments:Array<TypedExpression>, span:SourceSpan):TypedExpression {
		var pointee = rawPointee(arguments[0]);
		return TypeRepresentation.mentionsTypeParameter(pointee)
			? new TypedExpression(TParameterOperation(RawPointer(name),
			arguments), rawPointerResult(name, arguments[0], pointee), span) : rawPointerOperation(name, arguments,
			span);
	}

	static function rawPointee(receiver:TypedExpression):CompilerType
		return switch receiver.type {
			case TAbstract(_, [pointee], _): pointee;
			default: throw new InternalError("A raw pointer access on a value that is no RawPtr");
		};

	static function rawPointerResult(name:String, receiver:TypedExpression, pointee:CompilerType):CompilerType
		return switch name {
			case "load": pointee;
			case "store": TVoid;
			default: receiver.type;
		};

	/** `RawPtr.load`, `store` or `offset` (`name`) through `arguments[0]`, with its pointee's layout. */
	public function rawPointerOperation(name:String, arguments:Array<TypedExpression>,
			span:SourceSpan):TypedExpression {
		var receiver = arguments[0], pointee = rawPointee(receiver);
		return switch name {
			case "load" if (flatValueRecordName(pointee) != null):
				new TypedExpression(TCall("$rawptr.load.flat", [receiver]), pointee, span);
			case "load":
				var layout = nativeMemoryLayout(pointee, span);
				new TypedExpression(TCall("$rawptr.load", [
					receiver,
					new TypedExpression(TIntLiteral(layout.size), TInt, span),
					new TypedExpression(TBoolLiteral(layout.signed), TBool, span)
				]), pointee, span);
			case "store" if (flatValueRecordName(pointee) != null):
				new TypedExpression(TCall("$rawptr.store.flat", [receiver, arguments[1]]), TVoid, span);
			case "store":
				new TypedExpression(TCall("$rawptr.store", [
					receiver,
					arguments[1],
					new TypedExpression(TIntLiteral(nativeMemoryLayout(pointee, span).size), TInt, span)
				]), TVoid, span);
			case "offset":
				new TypedExpression(TCall("$rawptr.offset", [
					receiver,
					arguments[1],
					new TypedExpression(TIntLiteral(nativePointerStride(pointee, span)), TInt, span)
				]), receiver.type, span);
			default: throw new InternalError('Unknown raw pointer access "$name"');
		};
	}

	/** `Hashing.hash` of `value`, with the helper its type asks for. */
	public function hashCall(value:TypedExpression, span:SourceSpan):TypedExpression {
		var keyed = HashGenerator.request(session, value.type, session.currentContext.name, span);
		return new TypedExpression(TCall(HashGenerator.hashName(keyed), [value]), TInt, span);
	}

	/**
	 * `left` compared with `right`, already converted to `left`'s type, by the equality intrinsic `name` (`Equality.equals`,
	 * `Equality.sameForChange` or `Hashing.keyEquals`), with the helper their type asks for.
	 */
	public function equalityCall(name:String, left:TypedExpression, right:TypedExpression,
			span:SourceSpan):TypedExpression {
		var mapKeyEquality = name == "Hashing.keyEquals" || name == "haxeon.Hashing.keyEquals";
		if ((name == "Equality.sameForChange" || name == "haxeon.Equality.sameForChange") && (switch left.type {
			case TTypeParameter(_, _) | TDynamic: true;
			default: false;
		}))
			return new TypedExpression(TCall("$reactive.changeEquals", [left, right]), TBool, span);
		if (mapKeyEquality && !DeclaredConformance.supportsHash(session, left.type))
			fail("E1025", DeclaredConformance.capabilityError(session, left.type, "Hashable"), span);
		if ((mapKeyEquality || name == "Equality.sameForChange" || name == "haxeon.Equality.sameForChange")
			&& isFloatingMapKey(left.type))
			return new TypedExpression(TCall("$map.floatKeyEquals", [left, right]), TBool, span);
		if ((switch (left.type) {
			case TDynamic: true;
			default: false;
		}))
			return new TypedExpression(TCall("__dynamic_equal", [
				left,
				bodyTyper.coerce(right, TDynamic, "dynamic equality operand", "E1002")
			]), TBool, span);
		var explicitEquality = name == "Equality.equals" || name == "haxeon.Equality.equals";
		if (explicitEquality && !DeclaredConformance.supportsEquality(session, left.type))
			fail("E1025", DeclaredConformance.capabilityError(session, left.type, "Equatable"), span);
		if (explicitEquality) {
			// A plain abstract compares as its representation, as its == does.
			var leftValue = DeclaredConformance.abstractEqualityOperand(session, left),
				rightValue = DeclaredConformance.abstractEqualityOperand(session, right);
			if (leftValue != null && rightValue != null) {
				left = leftValue;
				right = rightValue;
			}
		}
		if (!explicitEquality && !mapKeyEquality && DeclaredConformance.usesIdentityEquality(left.type))
			return new TypedExpression(TEqual(left, right), TBool, span);
		var structType = switch left.type {
			case TNullable(element) if (session.relations.isStruct(element)): element;
			default: left.type;
		};
		var typeParameter = switch left.type {
			case TTypeParameter(_, _): true;
			default: false;
		};
		if (session.relations.isStruct(structType) && !DeclaredConformance.supportsEquality(session, structType))
			fail("E1025",
				'Struct "${compiler.semantic.SemanticSignature.display(structType)}" does not conform to Equatable',
				span);
		var enumType = switch left.type {
			case TInstance(NominalKind.Enum, _, _): true;
			case TNullable(TInstance(NominalKind.Enum, _, _)): true;
			default: false;
		};
		if (enumType) {
			if (!DeclaredConformance.supportsEquality(session, left.type))
				fail("E1025",
					'Enum "${compiler.semantic.SemanticSignature.display(left.type)}" does not conform to Equatable',
					span);
			var keyed = EnumEqualityGenerator.request(session, left.type, session.currentContext.name, span);
			return new TypedExpression(TCall(EnumEqualityGenerator.equalsName(keyed), [left, right]), TBool, span);
		}
		if (DeclaredConformance.usesEquality(session, left.type) && !typeParameter) {
			var keyed = ValueEqualityGenerator.request(session, left.type, session.currentContext.name, span);
			return new TypedExpression(TCall(ValueEqualityGenerator.equalsName(keyed), [left, right]), TBool, span);
		}
		return new TypedExpression(TEqual(left, right), TBool, span);
	}

	public function typeClosureCall(callee:AstExpression, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			callableName:Null<String> = null,
			invalidateAllExpressions:Bool = true, ?expectedType:CompilerType):TypedExpression {
		// A `try` expression is an immediately called lambda; where its value is discarded, its branches may differ in type.
		var discarded = (switch (expectedType) {
			case TVoid: true;
			default: false;
		}) && arguments.length == 0 && switch callee {
			case Lambda(lambdaArguments, _, _, _): lambdaArguments.length == 0;
			default: false;
		}, typedCallee = bodyTyper.typeExpression(callee, scope, discarded ? TFunction([], TVoid, []) : null),
			functionType = switch typedCallee.type {
			case TFunction(parameters, result, optional): {arguments: parameters, result: result, optional: optional};
			default: null;
		};
		if ((switch (typedCallee.type) {
			case TDynamic: true;
			default: false;
		})) {
			var typedArguments = [
				for (argument in arguments)
					bodyTyper.coerce(bodyTyper.typeExpression(argument, scope, TDynamic), TDynamic,
					"argument to dynamic function")
			];
			session.invalidateUnknownCall(scope);
			return new TypedExpression(TClosureCall(typedCallee, typedArguments), TDynamic, span);
		}
		if (functionType == null)
			fail("E1007", callableName == null
				? "Cannot call non-function expression" : 'Cannot call non-function "$callableName"', span);
		var restIndex = functionType.arguments.length - 1;
		arguments = restIndex >= 0
			&& RestArguments.isRestValue(functionType.arguments[restIndex]) ? RestArguments.packAt(restIndex,
			arguments, span) : RestArguments.packAt(-1, arguments, span);
		var calleeLocal = callableName == null ? null : bodyTyper.localAt(callee, scope),
			calleeFunction = calleeLocal == null ? null : calleeLocal.localFunction,
			localParameters = calleeFunction == null ? null : calleeFunction.arguments;
		if (localParameters != null && localParameters.length != functionType.arguments.length)
			localParameters = null;
		// A call may omit the arguments the function type flags optional, as in Haxe; the function fills their defaults.
		var required = FunctionTypes.requiredCount(functionType.optional, functionType.arguments.length);
		if (localParameters != null)
			while (required > 0 && AstPredicates.isOptionalArgument(localParameters[required - 1]))
				required--;
		if (arguments.length < required || arguments.length > functionType.arguments.length)
			fail("E1008",
				callableName == null
				? 'Function expression expects ${functionType.arguments.length} arguments, got ${arguments.length}'
				: 'Function value "$callableName" expects ${functionType.arguments.length} arguments, got ${arguments.length}',
				span);
		var typedArguments = [
			for (index in 0...arguments.length)
				bodyTyper.typeExpression(arguments[index], scope, functionType.arguments[index])
		];
		// An omitted argument is passed as null: the function that runs replaces it with its own default. A local function
		// whose declared type takes the value itself (`function add(extra:Int = 2):Int`) is called with its default.
		for (index in arguments.length...functionType.arguments.length) {
			var parameter = localParameters == null ? null : localParameters[index];
			typedArguments.push(parameter != null
				&& DefaultArguments.valueDefault(parameter, functionType.arguments[index], session.relations)
				? bodyTyper.typeDefaultExpression(parameter, functionType.arguments[index],
				callableName) : new TypedExpression(TNullLiteral, TNull, span));
		}
		typedArguments = coerceArguments(typedArguments, functionType.arguments,
			callableName == null ? "function expression" : callableName);
		invalidateClosureWrites(callee, callableName, scope);
		if (invalidateAllExpressions)
			scope.invalidateAllExpressions();
		return new TypedExpression(TClosureCall(typedCallee, typedArguments), functionType.result, span);
	}

	function invalidateClosureWrites(callee:AstExpression, callableName:Null<String>, scope:Scope):Void {
		if (callableName == null)
			switch callee {
				case Variable(name, _):
					callableName = name;
				default:
			}
		var effects = calledClosureEffects(callee, callableName, scope);
		for (captured in session.closureWritableBindings(scope))
			if (effects == null || effects.unknown || effects.writes.exists(captured.source))
				scope.invalidateBinding(captured);
	}

	/**
	 * What the closure being called can assign, when it is known: a lambda called where it is written, or a local
	 * function that is never reassigned. Null for any other function value, which may assign anything captured.
	 */
	/** The local `name` at `span` refers to, in `scope` (`ClosureEffects.LocalResolver`). */
	function outerLocal(name:String, span:SourceSpan, scope:Scope):Null<compiler.types.analysis.Scope.LocalBinding>
		return bodyTyper.localAt(Variable(name, span), scope);

	function calledClosureEffects(callee:AstExpression, callableName:Null<String>, scope:Scope):Null<ClosureEffects> {
		switch callee {
			case Lambda(arguments, body, _, _):
				return ClosureEffects.of(arguments, body, scope, outerLocal, null, session.isPureCall);
			default:
		}
		var calleeLocal = callableName == null ? null : bodyTyper.localAt(callee, scope),
			known = calleeLocal == null ? null : calleeLocal.localFunction;
		if (known == null)
			return null;
		return ClosureEffects.of(known.arguments, known.body, known.declaredIn == null ? scope : known.declaredIn,
			outerLocal, [known], session.isPureCall);
	}

	public function resolveFunctionCall(name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope):TypedExpression {
		// A static method of a class or abstract by its qualified name (`C.m()`, or `m()` inside C); module functions have no info.
		var calledMethod = session.methodInfo.get(name);
		if (calledMethod != null)
			MemberAccess.method(session, calledMethod.owner, name.substr(name.lastIndexOf(".") + 1), span);
		var hasSignature = session.signatures.exists(name);
		if (hasSignature && BodyTyper.functionTypeParameters(requiredMapValue(session.signatures, name)).length > 0) {
			var signature = requiredMapValue(session.signatures, name),
				infoOwner:Null<String> = null,
				infoStatic = true;
			if (session.methodInfo.exists(name)) {
				var resolvedInfo = requiredMapValue(session.methodInfo, name);
				infoOwner = resolvedInfo.owner;
				infoStatic = resolvedInfo.isStatic;
			}
			var prepared = typeGenericCallArguments(signature, arguments, scope, span);
			return genericInstantiation.specialize(name, signature, prepared.arguments, span, scope, infoOwner,
				infoStatic, prepared.substitutions);
		}
		var expectedArguments:Array<CompilerType> = [],
			result:CompilerType = TVoid;
		if (hasSignature) {
			var signature = requiredMapValue(session.signatures, name);
			expectedArguments = bodyTyper.argumentTypesOf(signature);
			result = bodyTyper.functionResultType(signature, signature.span);
		} else if (session.externals.exists(name)) {
			var external = requiredMapValue(session.externals, name);
			expectedArguments = external.arguments;
			result = external.result;
		} else
			fail("E1007", 'Unknown function "$name"', span);
		// trace takes any value and any further values, as Haxe's `trace(v:Dynamic, ...rest)` does (the rest become the position's
		// customParams), and prints a line in haxe.Log's form: "path/File.hx:12: v, p1, p2", each value as Std.string gives it and
		// the path relative to its source root. The newline matters beyond looks: hosts that print by line (a browser console)
		// would otherwise hold it back.
		var traced = name == "trace" && !hasSignature;
		if (traced && arguments.length == 0)
			fail("E1008", 'Function "trace" expects at least 1 argument, got 0', span);
		if (!traced && !hasSignature && arguments.length != expectedArguments.length)
			fail("E1008", 'Function "$name" expects ${expectedArguments.length} arguments, got ${arguments.length}',
				span);
		var typed = traced ? [traceLine(arguments, scope, span)] : hasSignature ? typeDeclaredCallArguments(arguments,
			requiredMapValue(session.signatures, name), scope, name,
			span) : typeCallArguments(arguments, expectedArguments, scope, name);
		var call = new TypedExpression(session.cNativeFunctions.exists(name) ? TCNativeCall(name, typed) : TCall(name,
			typed), result, span);
		session.invalidateCallEffects(name, scope);
		return session.isNoReturnCall(name) ? new TypedExpression(TNoReturn(call), TNever, call.span) : call;
	}

	/** The line `trace(v, p1, ...)` prints: its location, then each value converted as Std.string converts it, joined by ", ". */
	function traceLine(arguments:Array<AstExpression>, scope:Scope, span:SourceSpan):TypedExpression {
		function text(value:String):TypedExpression
			return new TypedExpression(TStringLiteral(value), TString, span);
		function join(left:TypedExpression, right:TypedExpression):TypedExpression
			return new TypedExpression(TAdd(left, right), TString, span);
		var line = text(span.file.path + ":" + span.file.lineAt(span.start) + ": ");
		for (index in 0...arguments.length) {
			if (index > 0)
				line = join(line, text(", "));
			line = join(line, StringConversion.convert(session,
				bodyTyper.typeExpression(arguments[index], scope, TDynamic), bodyTyper));
		}
		return join(line, text("\n"));
	}

	public function resolveImplicitMethodCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):Null<TypedExpression> {
		var owner = session.currentContext.lexicalOwner;
		if (name.indexOf(".") >= 0 || owner == null)
			return null;
		// An abstract's own instance method called without a receiver is a call on `this`, whose type
		// arguments are the method's: they are not inferred again from the call's arguments.
		var abstractDeclaration = session.declarations.abstracts.get(owner);
		if (abstractDeclaration != null && scope.receiverType() != null)
			for (candidate in abstractDeclaration.methods)
				if (candidate.name == name && !candidate.isStatic && candidate.name != "new")
					return typeAbstractMethodCall(session.representation
						.boundaryCast(typeExpressionValue(Variable("this", span), scope),
						scope.receiverType()), name, arguments, span,
						scope);
		var methodInfo = findMethod(owner, name);
		if (methodInfo == null)
			return null;
		var methodKey = methodInfo.owner + "." + name,
			method = session.signatures.get(methodKey);
		if (method == null)
			fail("E1007", 'Missing signature for method "$methodKey"', span);
		MemberAccess.method(session, methodInfo.owner, name, span);
		if (BodyTyper.functionTypeParameters(method).length > 0) {
			var receiver:Null<TypedExpression> = null;
			if (!methodInfo.isStatic) {
				if (scope.receiverType() == null)
					fail("E1007", 'Instance method "$methodKey" requires an object', span);
				receiver = typeExpressionValue(Variable("this", span), scope);
			}
			var preset:Map<String, CompilerType> = [],
				parameters = BodyTyper.functionTypeParameters(method);
			// A Void expectation is a statement whose result is discarded, not a result of type Void.
			if (expectedType != null && !sameType(expectedType, TVoid))
				genericInstantiation.inferTypeParameters(method.result, expectedType, parameters, preset, span);
			var prepared = typeGenericCallArguments(method, arguments, scope, span, null, preset);
			return genericInstantiation.specialize(methodKey, method, prepared.arguments, span, scope, methodInfo.owner,
				methodInfo.isStatic,
				prepared.substitutions, receiver);
		}
		if (methodInfo.isStatic) {
			var typed = typeDeclaredCallArguments(arguments, method, scope, methodKey, span);
			return applyCallEffect(new TypedExpression(TCall(methodKey, typed),
				bodyTyper.functionResultType(method, method.span),
				span), methodKey, scope);
		}
		if (scope.receiverType() == null)
			fail("E1007", 'Instance method "$methodKey" requires an object', span);
		var receiver = typeExpressionValue(Variable("this", span), scope),
			methodOwnerType = projectNominal(receiver.type, methodInfo.owner),
			substitutions = session.representation.nominalSubstitutions(methodOwnerType),
			semanticArguments = typeDeclaredCallArguments(arguments, method, scope, methodKey, span,
				substitutions, method.isExtern != true),
			physicalArguments = session.representation.adaptMethodArguments(methodOwnerType, methodInfo.owner, method,
				semanticArguments, method.isExtern != true),
			methodResult = session.representation.resolveMethodResult(methodOwnerType, methodInfo.owner, method),
			call = new TypedExpression(TMethodCall(receiver, methodKey, physicalArguments), methodResult.physical,
				span);
		return applyCallEffect(session.representation.memberResultBoundary(call, methodResult, methodOwnerType,
			methodInfo.owner, method), methodKey, scope);
	}

	public function typeNamedCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):TypedExpression {
		var rawOwnerEnd = name.lastIndexOf(".");
		if (rawOwnerEnd > 0) {
			var written = name.substring(0, rawOwnerEnd),
				abstractName = session.enumAbstractName(written),
				owner = abstractName == null ? written : abstractName,
				member = name.substring(rawOwnerEnd + 1),
				declaration = abstractName == null ? null : session.enumAbstractDecls.get(abstractName);
			if (declaration != null && FlagsGenerator.conforms(session, declaration)
				&& FlagsGenerator.isMember(member, true)) {
				var info = FlagsGenerator.signature(owner, member),
					typed = typeCallArguments(arguments, info.arguments, scope, name);
				return new TypedExpression(TCall(FlagsGenerator.request(session, owner, member, span), typed),
					info.result, span);
			}
		}

		if (rawOwnerEnd > 0 && name.substring(rawOwnerEnd + 1) == "fromRaw") {
			var rawOwner = session.enumAbstractName(name.substring(0, rawOwnerEnd)),
				declaration = rawOwner == null ? null : session.enumAbstractDecls.get(rawOwner);
			if (declaration != null && RawRepresentableGenerator.conforms(session, declaration)) {
				if (arguments.length != 1)
					fail("E1008", "fromRaw expects one argument", span);
				var raw = bodyTyper.lowerType(declaration.underlying, declaration.span),
					argument = bodyTyper.coerce(bodyTyper.typeExpression(arguments[0], scope, raw), raw,
						"fromRaw argument");
				return new TypedExpression(TCall(RawRepresentableGenerator.request(session, rawOwner, "fromRaw", span),
					[argument]),
					TNullable(TAbstract(rawOwner, [], raw)), span);
			}
		}
		if (StringTools.startsWith(name, "super.") && name.indexOf(".", 6) < 0)
			return typeSuperMethodCall(name.substring(6), arguments, span, scope);
		// A canonical module function is only the fallback for a bare source call; members still win.
		var sourceName = span.isBareReference ? span.referenceName : null;
		if (sourceName != null && sourceName.indexOf(".") < 0 && sourceName != name) {
			var fieldCall = typeImplicitFunctionFieldCall(sourceName, arguments, span, scope);
			if (fieldCall != null)
				return fieldCall;
			var methodCall = resolveImplicitMethodCall(sourceName, arguments, span, scope, expectedType);
			if (methodCall != null)
				return methodCall;
		}
		var calleeLocal = bodyTyper.localAt(Variable(name, span), scope);
		if (calleeLocal != null) {
			// A local function runs a known body, so a call through it only clears facts when that body might.
			var local = calleeLocal.localFunction;
			return typeClosureCall(Variable(name, span), arguments, span, scope, name,
				local == null || !session.localFunctionIsPure(local,
				session.currentContext.lexicalOwner));
		}
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
			methodName:Null<String> = null,
			firstMember = 1;
		if (parts.length >= 2) {
			methodName = parts[parts.length - 1];
			if (!session.signatures.exists(name)) {
				// A value in scope wins; otherwise the longest dotted prefix that
				// names a type is the receiver, so "pkg.Type.FIELD.method()"
				// types FIELD as a static member of pkg.Type.
				var sourceParts = span.referenceName == null ? parts : splitPath(span.referenceName);
				receiverName = sourceParts[0];
				receiver = bodyTyper.resolveReceiver(receiverName, span, scope);
				if (receiver != null)
					parts = sourceParts;
				var prefixLength = parts.length - 1;
				while (receiver == null && prefixLength >= 1) {
					var prefix = parts.slice(0, prefixLength).join(".");
					var referenced = typeReference(prefix);
					if (referenced != null) {
						receiverName = prefix;
						receiver = new TypedExpression(TClassRef(referenced),
							TInstance(NominalKind.Class, referenced, []), span);
						firstMember = prefixLength;
					}
					prefixLength--;
				}
			}
		}
		if (receiver != null)
			for (index in firstMember...parts.length - 1)
				receiver = bodyTyper.typedMemberWithFlow(receiver, parts[index],
					BodyTyper.referencePrefixSpan(parts.slice(0, index + 1).join("."), span), scope);
		if (receiver != null)
			receiver = unwrapNullable(receiver);
		var expectedEnumName = enumName(expectedType);
		var constructorName = name.indexOf(".") < 0 ? name : compiler.core.QualifiedName.last(name);
		var enumCase = expectedEnumName != null
			&& sourceIsBareReference(span) ? enumCaseInfo(expectedEnumName + "." + constructorName) : null;
		if (enumCase == null) {
			enumCase = enumCaseInfo(name);
			if (enumCase == null && expectedEnumName != null && name.indexOf(".") < 0)
				enumCase = enumCaseInfo(expectedEnumName + "." + constructorName);
			if (enumCase == null && name.indexOf(".") < 0)
				enumCase = uniqueEnumCaseInfo(constructorName, arguments.length, span);
		}
		if (enumCase != null)
			return typeEnumConstructor(name, arguments, expectedType, enumCase, span, scope);
		if (receiver != null && methodName != null) {
			if (isEnumMatch(receiver, methodName, arguments))
				return typeEnumMatch(Variable(name.substring(0, name.lastIndexOf(".")), span), arguments[0], span,
					scope);
			return typeMethodCall(receiver, methodName, arguments, span, scope, expectedType, false, receiverName,
				false);
		}
		// Nothing else names the receiver: a constructor without arguments can ("Color.Red.getIndex()", "Red.getIndex()"), and
		// so can an enum abstract value ("Color.Blue.label()", "Blue.label()").
		if (methodName != null && !session.signatures.exists(name)) {
			var prefix = name.substring(0, name.lastIndexOf(".")),
				constructor = enumCaseInfo(prefix);
			if (constructor == null && prefix.indexOf(".") < 0)
				constructor = uniqueEnumCaseInfo(prefix, 0, span);
			if (constructor != null && constructor.params.length == 0) {
				var value = typeEnumConstructor(prefix, [], null, constructor, span, scope);
				if (isEnumMatch(value, methodName, arguments))
					return typeEnumMatch(Variable(prefix, span), arguments[0], span, scope);
				return typeMethodCall(value, methodName,
					arguments, span, scope, expectedType,
					false, prefix, false);
			}
			var abstractValue = bodyTyper.enumAbstractValueReference(prefix,
				BodyTyper.referencePrefixSpan(prefix, span));
			if (abstractValue != null)
				return typeMethodCall(abstractValue, methodName, arguments, span, scope, expectedType, false, prefix,
					false);
		}
		return resolveFunctionCall(name, arguments, span, scope);
	}

	function typeEnumConstructor(name:String, arguments:Array<AstExpression>, expectedType:Null<CompilerType>,
			enumCase:EnumConstructorInfo, span:SourceSpan,
			scope:Scope):TypedExpression {
		var required = requiredEnumParameters(enumCase.params);
		if (arguments.length < required || arguments.length > enumCase.params.length)
			fail("E1008",
				'Enum constructor "$name" expects $required to ${enumCase.params.length} arguments, got ${arguments.length}',
				span);
		var instance = enumCase.aliasType ?? enumInstanceOf(enumCase, expectedType),
			typedArguments:Array<TypedExpression>;
		if (instance == null && enumCase.typeParameters.length == 0)
			instance = TInstance(NominalKind.Enum, enumCase.enumName, []);
		if (instance == null) {
			// A generic enum's constructor infers its type parameters as a generic function call does, from its arguments
			// (`GenericInstantiation.constructedEnumType`).
			var parameters = enumCase.typeParameters;
			var declared:Array<AstArgument> = [];
			for (parameter in enumCase.params)
				declared.push({name: parameter.name ?? "", type: parameter.type, span: parameter.span});
			var prepared = typeGenericArguments(parameters, declared, arguments, scope, span);
			typedArguments = prepared.arguments;
			instance = genericInstantiation.constructedEnumType(enumCase.enumName, parameters, prepared.substitutions,
				span);
		} else
			typedArguments = [
				for (index in 0...arguments.length)
					bodyTyper.typeExpression(arguments[index], scope,
					enumParameterType(enumCase.typeParameters, enumCase.params[index], instance))
			];
		var expected = [
			for (parameter in enumCase.params)
				enumParameterType(enumCase.typeParameters, parameter, instance)
		];
		while (typedArguments.length < expected.length)
			typedArguments.push(new TypedExpression(TNullLiteral, TNull, span));
		typedArguments = coerceArguments(typedArguments, expected, name);
		// The constructed enum's storage is named after its type arguments, so a literal's structure among them closes here.
		var resultType:CompilerType = enumCase.aliasType ?? session.monomorphs.closeReached(instance);
		if (enumCase.aliasType == null && enumInstanceOf(enumCase, expectedType) != null)
			resultType = expectedType;
		for (index in 0...typedArguments.length)
			typedArguments[index] = session.representation.boundaryCast(typedArguments[index],
				session.representation.enumStorageType(enumCase.typeParameters, enumCase.params[index], resultType));
		return new TypedExpression(TEnumConstruct(enumCase.enumName, enumCase.index, typedArguments), resultType, span,
			false, null, null, enumCase.aliasName);
	}

	/**
	 * The instance of `enumCase`'s enum that `expectedType` names with every type argument (`Option<Int>`, also through `Null<>`
	 * or an abstract), whose arguments the constructor takes; null when it names none.
	 */
	static function enumInstanceOf(enumCase:EnumConstructorInfo, expectedType:Null<CompilerType>):Null<CompilerType> {
		var instance = enumInstance(expectedType);
		return switch instance {
			case TInstance(Enum, name, arguments) if ((name:String) == enumCase.enumName
				&& arguments.length == enumCase.typeParameters.length):
				instance;
			default: null;
		};
	}

	/**
	 * The index of the constructor without arguments that `owner.field` always holds: a static `final` field initialized
	 * with one (`static final DEFAULT = Mode.Fast;`, or a bare constructor of an enum in the same file), else -1.
	 */
	public function staticFinalConstructor(owner:String, field:String):Int {
		var classDecl = session.classDecls.get(owner);
		if (classDecl == null)
			return -1;
		for (candidate in classDecl.fields) {
			if (candidate.name != field || !candidate.isStatic || !candidate.isFinal)
				continue;
			var initializer = candidate.initializer;
			var path = initializer == null ? null : switch initializer {
				case Variable(name, _): name;
				case Member(Variable(owner, _), name, _): owner + "." + name;
				default: null;
			};
			if (path == null)
				return -1;
			var constructor = path.indexOf(".") < 0 ? uniqueEnumCaseInfo(path, 0, candidate.span) : enumCaseInfo(path);
			return constructor == null || constructor.params.length > 0 ? -1 : constructor.index;
		}
		return -1;
	}

	public function enumCaseInfo(name:String):Null<EnumConstructorInfo> {
		var separator = name.lastIndexOf(".");
		if (separator < 0)
			return null;
		var qualifier = name.substring(0, separator),
			qualifiedType = session.declarations.enumQualifierType(qualifier),
			enumName = enumName(qualifiedType),
			caseName = name.substring(separator + 1);
		if (enumName == null || !session.enumDecls.exists(enumName))
			return null;
		var declaration = requiredMapValue(session.enumDecls, enumName);
		for (index in 0...declaration.cases.length)
			if (declaration.cases[index].name == caseName)
				return {
					aliasType: qualifier == enumName ? null : qualifiedType,
					aliasName: qualifier == enumName ? null : qualifier,
					enumName: enumName,
					index: index,
					params: declaration.cases[index].params,
					typeParameters: declaration.typeParameters
				};
		return null;
	}

	function uniqueEnumCaseInfo(name:String, argumentCount:Int, span:SourceSpan):Null<EnumConstructorInfo> {
		var found:Null<EnumConstructorInfo> = null;
		for (entry in session.enumsInFile(span.file.path)) {
			var declaration = entry.declaration;
			for (index in 0...declaration.cases.length) {
				var enumCase = declaration.cases[index];
				if (enumCase.name != name
					|| argumentCount < requiredEnumParameters(enumCase.params)
					|| argumentCount > enumCase.params.length)
					continue;
				if (found != null)
					return null;
				found = {
					enumName: entry.name,
					index: index,
					params: enumCase.params,
					typeParameters: declaration.typeParameters
				};
			}
		}
		return found;
	}

	static function sourceIsBareReference(span:SourceSpan):Bool
		return span.isBareReference;

	function enumParameterType(typeParameters:Array<String>, parameter:AstEnumParameter,
			instance:Null<CompilerType>):CompilerType {
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

	/** The type a qualified name denotes, when its static members can be accessed: the name itself, or the enum abstract a typedef names. */
	function typeReference(name:String):Null<String> {
		if (session.classDecls.exists(name) || PlatformAbi.isType(name))
			return name;
		return session.enumAbstractName(name);
	}

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
			fail("E1008",
				'Constructor "$resolvedBase" expects ${resolvedExpected.length} arguments, got ${arguments.length}',
				span);
		MemberAccess.method(session, resolvedBase, "new", span);
		var semanticArguments = hasConstructor ? typeDeclaredCallArguments(arguments,
			requiredMapValue(session.signatures, constructorName), scope,
			constructorName, span, substitutions) : typeCallArguments(arguments, resolvedExpected, scope,
			constructorName),
			method = hasConstructor ? requiredMapValue(session.signatures, constructorName) : null,
			physicalArguments = session.representation.adaptConstructorArguments(baseInstance, resolvedBase, method,
				semanticArguments);
		return new TypedExpression(TSuperCall(resolvedBase, physicalArguments), TVoid, span);
	}

	/** `super.name(...)` calls the base-class body directly, bypassing virtual dispatch. */
	function typeSuperMethodCall(name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope):TypedExpression {
		var owner = session.currentContext.lexicalOwner,
			baseType:Null<AstType> = null;
		if (owner != null && session.classDecls.exists(owner))
			baseType = requiredMapValue(session.classDecls, owner).base;
		if (baseType == null)
			fail("E1007", 'super.$name() requires a base class', span);
		if (scope.receiverType() == null)
			fail("E1007", 'super.$name() requires an instance method', span);
		var baseName = switch session.declarations.resolve(baseType, span, session.currentContext.typeSubstitutions) {
			case TInstance(_, value, _): value;
			default: null;
		};
		var methodInfo = baseName == null ? null : findMethod(baseName, name);
		if (methodInfo == null || methodInfo.isStatic)
			fail("E1007", 'Base class has no instance method "$name"', span);
		var methodKey = methodInfo.owner + "." + name,
			method = session.signatures.get(methodKey);
		if (method == null || method.isExtern == true)
			fail("E1007", 'Missing body for base method "$methodKey"', span);
		MemberAccess.method(session, methodInfo.owner, name, span);
		if (BodyTyper.functionTypeParameters(method).length > 0)
			fail("E1016", 'super.$name() cannot call a generic method yet', span);
		var receiver = typeExpressionValue(Variable("this", span), scope),
			methodOwnerType = projectNominal(receiver.type, methodInfo.owner),
			physicalOwner = session.representation.genericOwner(methodOwnerType),
			substitutions = session.representation.nominalSubstitutions(methodOwnerType),
			semanticArguments = typeDeclaredCallArguments(arguments, method, scope, methodKey, span,
				substitutions),
			physicalArguments = session.representation.adaptMethodArguments(methodOwnerType, methodInfo.owner, method,
				semanticArguments),
			methodResult = session.representation.resolveMethodResult(methodOwnerType, methodInfo.owner, method),
			call = new TypedExpression(TCall(physicalOwner == null ? methodKey : physicalOwner.name + "." + name,
				[receiver].concat(physicalArguments)),
				methodResult.physical, span);
		return applyCallEffect(session.representation.memberResultBoundary(call, methodResult, methodOwnerType,
			methodInfo.owner, method), methodKey, scope);
	}

	public function typeRuntimeDataCall(name:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope):Null<TypedExpression> {
		if (name == "RuntimeData.address" || name == "runtime.RuntimeData.address") {
			if (arguments.length != 1)
				fail("E1008", 'RuntimeData.address expects 1 argument, got ${arguments.length}', span);
			return new TypedExpression(TRuntimeDataAddress(runtimeDataBytes(arguments[0], span)), TInt, span);
		}
		if (name == "RuntimeData.loadI32" || name == "runtime.RuntimeData.loadI32") {
			if (arguments.length != 1)
				fail("E1008", 'RuntimeData.loadI32 expects 1 argument, got ${arguments.length}', span);
			var address = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TInt, "runtime data address",
				"E1002");
			return new TypedExpression(TCall("runtime.RuntimeData.loadI32", [address]), TInt, span);
		}
		return null;
	}

	public function typeBuiltinCall(name:String, arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType> = null):Null<TypedExpression> {
		if (name == "__reference_equal") {
			if (!span.file.isStandardLibrarySource)
				fail("E1025", '"__reference_equal" is a stdlib-only primitive; compare class references with ==', span);
			if (arguments.length != 2)
				fail("E1008", 'Function "$name" expects 2 arguments, got ${arguments.length}', span);
			var left = typeExpressionValue(arguments[0], scope),
				right = bodyTyper.coerce(typeExpressionValue(arguments[1], scope), left.type,
					"reference identity operand",
					"E1002");
			function isReferenceIdentityType(type:CompilerType):Bool
				return switch type {
					case TDynamic, TTypeParameter(_,
						_), TString, TBytes, THlBytes, TArray(_), TIterator(_), TMap(_, _),
						TInstance(NominalKind.Interface, _, _): true;
					case TInstance(NominalKind.Class, _, _): !session.relations.isStruct(type);
					case TNullable(inner): isReferenceIdentityType(inner);
					default: false;
				};
			if (!isReferenceIdentityType(left.type))
				fail("E1025",
					'Reference identity requires a managed object reference, got "${compiler.semantic.SemanticSignature.display(left.type)}"',
					span);
			return new TypedExpression(TCall("__reference_equal", [left, right]), TBool, span);
		}
		if (name == "$value.place") {
			if (arguments.length != 1)
				throw new InternalError("Invalid compiler-generated place binding");
			var value = typeExpressionValue(arguments[0], scope);
			ValuePlaceRules.requireWritable(session, value, span);
			return new TypedExpression(TCall("$value.place", [value]), value.type, span);
		}

		if (name == "Equality.equals"
			|| name == "haxeon.Equality.equals"
			|| name == "Equality.sameForChange"
			|| name == "haxeon.Equality.sameForChange"
			|| name == "Hashing.keyEquals"
			|| name == "haxeon.Hashing.keyEquals") {
			if (arguments.length != 2)
				fail("E1008", 'Function "$name" expects 2 arguments, got ${arguments.length}', span);
			var left = typeExpressionValue(arguments[0], scope),
				right = bodyTyper.coerce(bodyTyper.typeExpression(arguments[1], scope, left.type), left.type,
					"structural equality operand", "E1002");
			// On a type parameter's value, which equality applies is the representation's: the elaboration pass chooses it.
			if (TypeRepresentation.mentionsTypeParameter(left.type))
				return new TypedExpression(TParameterOperation(Equality(name), [left, right]), TBool, span);
			return equalityCall(name, left, right, span);
		}
		if (name == "Hashing.hash" || name == "haxeon.Hashing.hash") {
			if (arguments.length != 1)
				fail("E1008", 'Function "$name" expects 1 argument, got ${arguments.length}', span);
			var value = typeExpressionValue(arguments[0], scope);
			if (!DeclaredConformance.supportsHash(session, value.type))
				fail("E1025", DeclaredConformance.capabilityError(session, value.type, "Hashable"), span);
			// A type parameter's value hashes as its representation does: the elaboration pass chooses the helper.
			if (TypeRepresentation.mentionsTypeParameter(value.type))
				return new TypedExpression(TParameterOperation(Hash, [value]), TInt, span);
			return hashCall(value, span);
		}
		if (DiffIntrinsics.handles(name))
			return bodyTyper.typeExpression(DiffIntrinsics.expand(session, name, arguments, span,
				function(argument) return typeExpressionValue(argument, scope).type,
				function(argument) return typeExpressionValue(argument, scope)),
				scope, expectedType);
		if (name == "Type.enumIndex" || name == "Type.enumConstructor" || name == "Type.enumParameters"
			|| name == "Type.enumEq") {
			if (arguments.length == 0)
				fail("E1008", 'Function "$name" expects ${name == "Type.enumEq" ? 2 : 1} arguments, got 0', span);
			return typeEnumValueFunction(name, typeExpressionValue(arguments[0], scope), arguments.slice(1), span,
				scope);
		}
		if (StringTools.startsWith(name, StaticExtensions.ENUM_VALUE_TOOLS + ".")) {
			var typeFunction =
				StaticExtensions.enumValueTool(name.substr(StaticExtensions.ENUM_VALUE_TOOLS.length + 1));
			if (typeFunction != null)
				return typeBuiltinCall(typeFunction, arguments, span, scope, expectedType);
		}
		if (name == "JsonWire.encode" || name == "haxeon.wire.JsonWire.encode") {
			if (arguments.length != 1)
				fail("E1008", 'Function "$name" expects 1 argument, got ${arguments.length}', span);
			var value = typeExpressionValue(arguments[0], scope);
			var keyed = WireCodecGenerator.requestJson(session, value.type, session.currentContext.name, span);
			return new TypedExpression(TCall(WireCodecGenerator.jsonEncodeName(keyed), [value]), TString, span);
		}
		if (name == "JsonWire.decode" || name == "haxeon.wire.JsonWire.decode") {
			if (arguments.length != 1)
				fail("E1008", 'Function "$name" expects 1 argument, got ${arguments.length}', span);
			var resultType = switch expectedType {
				case null, TNull:
					throw new CompileError(new Diagnostic("E1009", "JsonWire.decode requires an expected result type",
						span));
				case type: type;
			};
			var source = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TString, "JsonWire.decode input",
				"E1002");
			var keyed = WireCodecGenerator.requestJson(session, resultType, session.currentContext.name, span);
			return new TypedExpression(TCall(WireCodecGenerator.jsonDecodeName(keyed), [source]), resultType,
				span);
		}
		if (name == "MessagePack.encode" || name == "haxeon.wire.MessagePack.encode") {
			if (arguments.length != 1)
				fail("E1008", 'Function "$name" expects 1 argument, got ${arguments.length}', span);
			var value = typeExpressionValue(arguments[0], scope);
			var keyed = WireCodecGenerator.request(session, value.type, session.currentContext.name, span);
			return new TypedExpression(TCall(WireCodecGenerator.encodeName(keyed), [value]), TBytes, span);
		}
		if (name == "MessagePack.decode" || name == "haxeon.wire.MessagePack.decode") {
			if (arguments.length != 1)
				fail("E1008", 'Function "$name" expects 1 argument, got ${arguments.length}', span);
			var resultType = switch expectedType {
				case null, TNull:
					throw new CompileError(new Diagnostic("E1009",
						"MessagePack.decode requires an expected result type", span));
				case type:
					type;
			};
			var bytes = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TBytes, "MessagePack.decode input",
				"E1002");
			var keyed = WireCodecGenerator.request(session, resultType, session.currentContext.name, span);
			return new TypedExpression(TCall(WireCodecGenerator.decodeName(keyed), [bytes]), resultType, span);
		}
		if (name == "Std.isOfType" || name == "Std.isExactType") {
			if (arguments.length != 2)
				fail("E1008", 'Function "Std.isOfType" expects 2 arguments, got ${arguments.length}', span);
			var targetName = switch arguments[1] {
				case Variable(value, _): value;
				default:
					fail("E1009", "Std.isOfType expects a type as its second argument", span);
					"";
			};
			if (bodyTyper.localAt(arguments[1], scope) != null)
				fail("E1009", "Std.isOfType expects a type as its second argument", span);
			if (name == "Std.isExactType" && !session.classDecls.exists(targetName))
				fail("E1009", "Std.isExactType expects a class as its second argument", span);
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
					// Runtime type tests name a declaration, not an instantiation; generic arguments are erased here.
					if (session.classDecls.exists(targetName)) TInstance(NominalKind.Class, targetName,
						[
							for (_ in requiredMapValue(session.classDecls, targetName).typeParameters)
								TDynamic
						]);
					else if (session.interfaceDecls.exists(targetName)) TInstance(NominalKind.Interface, targetName, [
						for (_ in requiredMapValue(session.interfaceDecls, targetName).typeParameters)
							TDynamic
					]);
					else TInstance(NominalKind.Enum, targetName, [
						for (_ in requiredMapValue(session.enumDecls, targetName).typeParameters)
							TDynamic
					]);
			};
			var value = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TDynamic, "Std.isOfType value",
				"E1002"),
				target = new TypedExpression(TClassRef(targetName), targetType, span);
			return new TypedExpression(TCall(name == "Std.isExactType" ? "__std_is_exact_type" : "__std_is_of_type", [
				value,
				target
			]), TBool, span);
		}
		if (name == "Std.downcast") {
			if (arguments.length != 2)
				fail("E1008", 'Function "Std.downcast" expects 2 arguments, got ${arguments.length}', span);
			var targetName = switch arguments[1] {
				case Variable(value, _): value;
				default:
					fail("E1009", "Std.downcast expects a class or interface as its second argument", span);
					"";
			};
			if (bodyTyper.localAt(arguments[1], scope) != null
				|| !(session.classDecls.exists(targetName) || session.interfaceDecls.exists(targetName)))
				fail("E1009", "Std.downcast expects a class or interface as its second argument", span);
			// `value` is evaluated once: test the held copy, then cast it or yield null.
			var held = new TemporaryLocal('$' + 'downcast:${span.start}'),
				test = Call("Std.isOfType", [TemporaryVariable(held, span), arguments[1]], span);
			return bodyTyper.typeExpression(BlockExpression([TemporaryDeclaration(held, null, arguments[0], span)],
				Conditional(test, Cast(TemporaryVariable(held, span), NamedType(targetName), span), NullLiteral(span),
				span),
				span),
				scope, expectedType);
		}
		if (name == "Reflect.compare") {
			if (arguments.length != 2)
				fail("E1008", 'Function "Reflect.compare" expects 2 arguments, got ${arguments.length}', span);
			var left = typeExpressionValue(arguments[0], scope),
				right = bodyTyper.typeExpression(arguments[1], scope, left.type);
			if (sameType(left.type, TString) && sameType(right.type, TString))
				return new TypedExpression(TCall("__string_compare_full", [left, right]), TInt, span);
			return null;
		}
		if (name == "Reflect.isObject") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Reflect.isObject" expects 1 argument, got ${arguments.length}', span);
			var value = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TDynamic, "Reflect.isObject value",
				"E1002");
			return new TypedExpression(TCall("__reflect_is_object", [value]), TBool, span);
		}
		if (name == "Math.ceil") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Math.ceil" expects 1 argument, got ${arguments.length}', span);
			var value = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TFloat, "Math.ceil value", "E1002");
			return new TypedExpression(TCall("__math_ceil", [value]), TInt, span);
		}
		if (name == "Math.floor") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Math.floor" expects 1 argument, got ${arguments.length}', span);
			var value = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TFloat, "Math.floor value", "E1002");
			return new TypedExpression(TCall("__math_floor", [value]), TInt, span);
		}
		if (name == "haxe.io.Bytes.ofString") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "haxe.io.Bytes.ofString" expects 1 or 2 arguments, got ${arguments.length}',
					span);
			var value = bodyTyper.coerce(bodyTyper.typeExpression(arguments[0], scope, TString), TString,
				"byte string", "E1002");
			return new TypedExpression(TCall("haxe.io.Bytes.ofString", [value]), TBytes, span);
		}
		if (name == "Std.int" || name == "Std.stdIntFloat") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Std.int" expects 1 argument, got ${arguments.length}', span);
			var value = ConversionResolver.plainValue(bodyTyper.typeExpression(arguments[0], scope,
				name == "Std.stdIntFloat" ? TFloat : null), bodyTyper);
			return switch value.type {
				case TInt: value;
				case TFloat: new TypedExpression(TCall("__std_int_f64", [value]), TInt, span);
				case TDynamic: new TypedExpression(TCall("__std_int_dynamic", [value]), TInt, span);
				default:
					fail("E1009", "Std.int expects an Int or Float", value.span);
					new TypedExpression(TIntLiteral(0), TInt, span);
			};
		}
		// Std.string, and the string interpolation that lowers to it, convert as concatenation does. Dynamic is the expected
		// type, as the stdlib signature gives it, so mixed branches such as `cond ? "a" : 1` still join.
		if (name == "Std.string" && arguments.length == 1)
			return StringConversion.convert(session, bodyTyper.typeExpression(arguments[0], scope, TDynamic),
				bodyTyper);
		if (name == "Std.stdString") {
			if (arguments.length != 1)
				fail("E1008", 'Function "Std.string" expects 1 argument, got ${arguments.length}', span);
			var typed = typeExpressionValue(arguments[0], scope),
				named = EnumAbstractValues.nameOf(session, typed, span);
			if (named != null)
				return named;
			var value = bodyTyper.coerce(typed, TDynamic, "Std.string value", "E1002");
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
			var length = ConversionResolver.plainValue(bodyTyper.typeExpression(arguments[1], scope, TInt),
				bodyTyper);
			if (!sameType(length.type, TInt))
				fail("E1009", "String.__alloc__ expects an Int length", length.span);
			return new TypedExpression(TCall("__string_from_bytes", [bytes, length]), TString, span);
		}
		if (name == "String.fromCharCode") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.fromCharCode" expects 1 argument, got ${arguments.length}', span);
			var code = ConversionResolver.plainValue(bodyTyper.typeExpression(arguments[0], scope, TInt),
				bodyTyper);
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
		return code >= 48 && code <= 57 ? code - 48 : code >= 65 && code <= 70 ? code - 55 : code >= 97
			&& code <= 102 ? code - 87 : -1;

	function applyCallEffect(call:TypedExpression, name:String, ?scope:Scope):TypedExpression {
		if (scope != null)
			session.invalidateCallEffects(name, scope);
		return session.isNoReturnCall(name) ? new TypedExpression(TNoReturn(call), TNever, call.span) : call;
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

	public function typeStringMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan,
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
			var needle = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, TString), TString,
				"String.indexOf needle");
			if (arguments.length == 1)
				return new TypedExpression(TStringIndexOf(receiver, needle), TInt, span);
			var start = bodyTyper.coerce(typeExpressionValue(arguments[1], scope, TInt), TInt,
				"String.indexOf start index");
			return new TypedExpression(TCall("__string_index_of_from", [receiver, needle, start]), TInt, span);
		}
		if (name == "lastIndexOf") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "String.lastIndexOf" expects 1 or 2 arguments, got ${arguments.length}', span);
			var needle = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, TString), TString,
				"String.lastIndexOf needle");
			if (arguments.length == 1)
				return new TypedExpression(TCall("__string_last_index_of", [receiver, needle]), TInt, span);
			var start = bodyTyper.coerce(typeExpressionValue(arguments[1], scope, TInt), TInt,
				"String.lastIndexOf start index");
			return new TypedExpression(TCall("__string_last_index_of_from", [receiver, needle, start]), TInt, span);
		}
		if (name == "substring" || name == "substr") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", 'Function "String.$name" expects 1 or 2 arguments, got ${arguments.length}', span);
			var start = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, TInt), TInt, 'String.$name start'),
				end:Null<TypedExpression> = arguments.length == 1
					? null : bodyTyper.coerce(typeExpressionValue(arguments[1], scope, TInt), TInt, 'String.$name end');
			if (name == "substr")
				return typeSubstr(receiver, start, end, span);
			return new TypedExpression(TStringSubstring(receiver, start, end), TString, span);
		}
		if (name == "charCodeAt") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.charCodeAt" expects 1 argument, got ${arguments.length}', span);
			var index = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, TInt), TInt,
				"String.charCodeAt index");
			return new TypedExpression(TStringCharCodeAt(receiver, index), TInt, span);
		}
		if (name == "charAt") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.charAt" expects 1 argument, got ${arguments.length}', span);
			var index = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, TInt), TInt, "String.charAt index");
			return new TypedExpression(TStringCharAt(receiver, index), TString, span);
		}
		if (name == "split") {
			if (arguments.length != 1)
				fail("E1008", 'Function "String.split" expects one argument, got ${arguments.length}', span);
			var separator = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, TString), TString,
				"String.split separator");
			return new TypedExpression(TCall("__string_split", [receiver, separator]), TArray(TString), span);
		}
		throw new MissingMember("E1007", 'Unknown String method "$name"', span);
	}

	/**
	 * `receiver.substr(position, length)` over the `substring` primitive. A negative position counts from the end of
	 * the string and a negative length selects nothing, as in Haxe. Unless the position and length are constants that
	 * need no adjustment, the receiver, position and length are evaluated once, in order, into temporaries.
	 */
	function typeSubstr(receiver:TypedExpression, position:TypedExpression, length:Null<TypedExpression>,
			span:SourceSpan):TypedExpression {
		function nonNegativeConstant(value:TypedExpression)
			return switch value.expression {
				case TIntLiteral(literal): literal >= 0;
				default: false;
			};
		if (nonNegativeConstant(position) && (length == null || nonNegativeConstant(length))) {
			var end = length == null ? null : new TypedExpression(TAdd(position, length), TInt, span);
			return new TypedExpression(TStringSubstring(receiver, position, end), TString, span);
		}
		var contextName = session.currentContext.name,
			id = session.counters.nextSubstring(contextName);
		var receiverName = '$' + 'substr-receiver:$contextName:$id',
			positionName = '$' + 'substr-position:$contextName:$id',
			lengthName = '$' + 'substr-length:$contextName:$id',
			startName = '$' + 'substr-start:$contextName:$id',
			receiverLocal = new TypedExpression(TLocal(receiverName), TString, span),
			positionLocal = new TypedExpression(TLocal(positionName), TInt, span),
			lengthLocal = new TypedExpression(TLocal(lengthName), TInt, span),
			startLocal = new TypedExpression(TLocal(startName), TInt, span),
			zero = new TypedExpression(TIntLiteral(0), TInt, span),
			fromEnd = new TypedExpression(TAdd(new TypedExpression(TStringLength(receiverLocal), TInt, span),
				positionLocal), TInt, span),
			normalized = new TypedExpression(TConditional(new TypedExpression(TLess(positionLocal, zero), TBool, span),
				new TypedExpression(TConditional(new TypedExpression(TLess(fromEnd, zero), TBool, span), zero, fromEnd),
				TInt, span), positionLocal),
				TInt, span),
			clampedLength = new TypedExpression(TConditional(new TypedExpression(TLess(lengthLocal, zero), TBool, span),
				zero, lengthLocal), TInt, span),
			end = length == null ? null : new TypedExpression(TAdd(startLocal, clampedLength), TInt, span),
			statements:Array<compiler.types.TypedAst.TypedStatement> = [
				TVar(receiverName, receiver, span),
				TVar(positionName, position, span)
			];
		if (length != null)
			statements.push(TVar(lengthName, length, span));
		statements.push(TVar(startName, normalized, span));
		return new TypedExpression(TBlockExpression(statements,
			new TypedExpression(TStringSubstring(receiverLocal, startLocal, end), TString, span)),
			TString, span);
	}

	static function isEnumValue(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Enum, _, _): true;
			default: false;
		};

	/**
	 * `Array.indexOf`, `contains` or `remove` (`name`) of `value`, of the element type, in `receiver`; with `request`, the
	 * element's equality helper is requested here.
	 */
	public function arraySearch(name:String, receiver:TypedExpression, value:TypedExpression, span:SourceSpan,
			request:Bool):TypedExpression {
		var element = switch receiver.type {
			case TArray(element): element;
			default: throw new InternalError("An array search on a value that is no array");
		};
		if (request)
			requestArrayValueEquality(element, span);
		if (name == "remove")
			return new TypedExpression(TCollectionCall(receiver, "remove", [value]), TBool, span);
		var base = switch element {
			case TNullable(inner): inner;
			default: element;
		};
		var index = new TypedExpression(TCollectionCall(receiver,
			(session.relations.isValueClass(base)
			|| isEnumValue(base)
			|| isDynamicType(base)) ? "value_index_of" : "index_of", [value]), TInt, span);
		return name == "indexOf" ? index : new TypedExpression(TLessEqual(new TypedExpression(TIntLiteral(0), TInt,
			span), index), TBool, span);
	}

	function requestArrayValueEquality(element:CompilerType, span:SourceSpan):Void {
		var value = switch element {
			case TNullable(inner): inner;
			default: element;
		};
		var enumValue = switch value {
			case TInstance(NominalKind.Enum, _, _): true;
			default: false;
		};
		if (enumValue) {
			if (!DeclaredConformance.has(session, value, "Equatable"))
				fail("E1025",
					'Enum "${compiler.semantic.SemanticSignature.display(value)}" does not conform to Equatable', span);
			EnumEqualityGenerator.request(session, element, session.currentContext.name, span);
			return;
		}
		if (!session.relations.isValueClass(value))
			return;
		if (!DeclaredConformance.has(session, value, "Equatable"))
			fail("E1025",
				'Struct "${compiler.semantic.SemanticSignature.display(value)}" does not conform to Equatable', span);
		ValueEqualityGenerator.request(session, element, session.currentContext.name, span);
	}

	public function typeArrayMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope):TypedExpression {
		var result = typeArrayMethodInner(receiver, name, arguments, span, scope);
		switch name {
			case "unshift" | "pop" | "shift" | "resize" | "remove" | "insert" | "reverse" | "splice" | "sort":
				scope.invalidateExpressionNamespace("array-entry:");
			default:
		}
		var element = switch receiver.type {
			case TArray(value): value;
			default: throw new InternalError("Not an array");
		}, value = switch element {
			case TNullable(inner): inner;
			default: element;
		};
		if ((name == "indexOf" || name == "contains" || name == "remove") && session.relations.isValueClass(value))
			session.invalidateUnknownCall(scope);
		return result;
	}

	function typeArrayMethodInner(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope):TypedExpression {
		var element = switch receiver.type {
			case TArray(value): value;
			default: throw new InternalError("Not an array");
		};
		// An element still to be fixed (`var list = []`) is checked once the push that fixes it has been typed.
		session.monomorphs.whenKnown(element, function() {
			if (RuntimeType.arrayName(session.monomorphs.settled(element)) == null)
				fail("E1016", "This array element type has no compiler-owned runtime ABI", span);
		});
		// A comparison with an element still to be fixed fixes it from the value compared, as Haxe unifies the two, before
		// what the method needs of the element (its equality, its storage) is decided.
		var comparedValue:Null<TypedExpression> = null;
		if ((name == "indexOf" || name == "contains" || name == "remove")
			&& arguments.length == 1
			&& compiler.types.Monomorphs.containsUnbound(element)) {
			comparedValue = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, element), element,
				"array element",
				"E1002");
			element = compiler.types.Monomorphs.resolve(element);
		}
		if (name == "push" || name == "add") {
			if (arguments.length != 1)
				fail("E1008", 'Array.$name expects one argument', span);
			var value = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, element), element, "array element",
				"E1002");
			return new TypedExpression(TArrayPush(receiver, value), TInt, span);
		}
		if (name == "exists") {
			if (arguments.length != 1)
				fail("E1008", "Array.exists expects one predicate", span);
			var predicateType = CompilerType.TFunction([element], TBool, []);
			var predicate = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, predicateType), predicateType,
				"array predicate", "E1002");
			invalidateClosureWrites(arguments[0], null, scope);
			scope.invalidateAllExpressions();
			var context = session.currentContext.name;
			var id = session.counters.nextFunctionAdapter(context);
			var prefix = "$array-exists:" + context + ":" + id;
			var arrayName = prefix + ":array",
				predicateName = prefix + ":predicate",
				indexName = prefix + ":index",
				resultName = prefix + ":result";
			var array = new TypedExpression(TLocal(arrayName), receiver.type, span);
			var index = new TypedExpression(TLocal(indexName), TInt, span);
			var call = new TypedExpression(TClosureCall(new TypedExpression(TLocal(predicateName), predicateType, span),
				[new TypedExpression(TIndex(array, index), element, span)]),
				TBool, span);
			var statements:Array<compiler.types.TypedAst.TypedStatement> = [
				TVar(arrayName, receiver, span),
				TVar(predicateName, predicate, span),
				TVar(indexName, new TypedExpression(TIntLiteral(0), TInt, span), span),
				TVar(resultName, new TypedExpression(TBoolLiteral(false), TBool, span), span),
				TWhile(new TypedExpression(TLess(index, new TypedExpression(TArrayLength(array), TInt, span)), TBool,
					span), [
						TIf(call, [
							TAssign(resultName, new TypedExpression(TBoolLiteral(true), TBool, span), span),
							TBreak(span)
						], [], span),
						TIncrement(indexName, TInt, 1, span)
					], span)
			];
			return new TypedExpression(TBlockExpression(statements,
				new TypedExpression(TLocal(resultName), TBool, span)), TBool, span);
		}

		if (name == "iterator") {
			if (arguments.length != 0)
				fail("E1008", "Array.iterator expects no arguments", span);
			return iterator(receiver, element, span);
		}
		if (name == "unshift") {
			if (arguments.length != 1)
				fail("E1008", "Array.unshift expects one argument", span);
			var value = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, element), element, "array element",
				"E1002");
			return new TypedExpression(TArrayUnshift(receiver, value), TInt, span);
		}
		if (name == "pop") {
			if (arguments.length != 0)
				fail("E1008", "Array.pop expects no arguments", span);
			return takeOrNull(receiver, element, array -> new TypedExpression(TArrayPop(array), element, span), span);
		}
		if (name == "shift") {
			if (arguments.length != 0)
				fail("E1008", "Array.shift expects no arguments", span);
			return takeOrNull(receiver, element,
				array -> new TypedExpression(TCollectionCall(array, "shift", []), element, span), span);
		}
		if (name == "resize") {
			if (arguments.length != 1)
				fail("E1008", "Array.resize expects one argument", span);
			var length = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TInt, "array length", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "resize", [length]), TVoid, span);
		}
		if (name == "remove") {
			if (arguments.length != 1)
				fail("E1008", "Array.remove expects one argument", span);
			var deferred = TypeRepresentation.mentionsTypeParameter(element);
			if (!deferred)
				requestArrayValueEquality(element, span);
			var value = comparedValue != null ? comparedValue
				: bodyTyper.coerce(typeExpressionValue(arguments[0], scope, element), element, "array element",
				"E1002");
			// On a type parameter's element, the equality the search uses is the representation's: the elaboration pass chooses it.
			return deferred ? new TypedExpression(TParameterOperation(ArraySearch("remove"), [receiver, value]),
				TBool, span) : arraySearch("remove", receiver, value, span, false);
		}
		if (name == "insert") {
			if (arguments.length != 2)
				fail("E1008", "Array.insert expects a position and value", span);
			var position = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TInt, "insert position", "E1002"),
				value = bodyTyper.coerce(typeExpressionValue(arguments[1], scope, element), element, "array element",
					"E1002");
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
			// Coerced as any argument is: a nullable array is read as the array, as in Haxe (null throws at run time).
			var other = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, TArray(element)), TArray(element),
				"Array.concat argument", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "concat", [other]), TArray(element), span);
		}
		if (name == "slice") {
			if (arguments.length < 1 || arguments.length > 2)
				fail("E1008", "Array.slice expects a start and optional end", span);
			var start = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TInt, "slice start", "E1002"),
				end = arguments.length == 2 ? bodyTyper.coerce(typeExpressionValue(arguments[1], scope), TInt,
					"slice end",
					"E1002") : new TypedExpression(TArrayLength(receiver), TInt, span);
			return new TypedExpression(TCollectionCall(receiver, "slice", [start, end]), TArray(element), span);
		}
		if (name == "splice") {
			if (arguments.length != 2)
				fail("E1008", "Array.splice expects a position and length", span);
			var position = bodyTyper.coerce(typeExpressionValue(arguments[0], scope), TInt, "splice position", "E1002"),
				length = bodyTyper.coerce(typeExpressionValue(arguments[1], scope), TInt, "splice length", "E1002");
			return new TypedExpression(TCollectionCall(receiver, "splice", [position, length]), TArray(element), span);
		}
		if (name == "sort") {
			if (arguments.length != 1)
				fail("E1008", "Array.sort expects one comparator", span);
			var comparatorType = CompilerType.TFunction([element, element], TInt, []),
				comparator = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, comparatorType), comparatorType,
					"array comparator", "E1002");
			invalidateClosureWrites(arguments[0], null, scope);
			scope.invalidateAllExpressions();
			return new TypedExpression(TArraySort(receiver, comparator), TVoid, span);
		}
		if (name == "join" && sameType(enumAbstractStorage(element), TString)) {
			if (arguments.length != 1)
				fail("E1008", "Array.join expects one separator", span);
			var separator = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, TString), TString,
				"join separator",
				"E1002");
			return new TypedExpression(TCollectionCall(receiver, "join", [separator]), TString, span);
		}
		if (name == "indexOf") {
			switch enumAbstractStorage(element) {
				case TInt, TFloat, TBool, TString, TNativeScalar("u32"):
				default:
					if (RuntimeType.arrayName(element) != "ref")
						fail("E1016", "Array.indexOf currently supports primitive, String, and reference arrays only",
							span);
			}
			if (arguments.length != 1)
				fail("E1008", "Array.indexOf expects one argument", span);
			var deferred = TypeRepresentation.mentionsTypeParameter(element);
			if (!deferred)
				requestArrayValueEquality(element, span);
			var value = comparedValue != null ? comparedValue
				: bodyTyper.coerce(typeExpressionValue(arguments[0], scope, element), element, "array element",
				"E1002");
			// On a type parameter's element, the equality the search uses is the representation's: the elaboration pass chooses it.
			return deferred ? new TypedExpression(TParameterOperation(ArraySearch("indexOf"), [receiver, value]),
				TInt, span) : arraySearch("indexOf", receiver, value, span, false);
		}
		if (name == "contains") {
			if (arguments.length != 1)
				fail("E1008", "Array.contains expects one argument", span);
			var deferred = TypeRepresentation.mentionsTypeParameter(element);
			if (!deferred)
				requestArrayValueEquality(element, span);
			var value = comparedValue != null ? comparedValue
				: bodyTyper.coerce(typeExpressionValue(arguments[0], scope, element), element, "array element",
				"E1002");
			// On a type parameter's element, the equality the search uses is the representation's: the elaboration pass chooses it.
			return deferred ? new TypedExpression(TParameterOperation(ArraySearch("contains"), [receiver, value]),
				TBool, span) : arraySearch("contains", receiver, value, span, false);
		}
		var library = typeLibraryArrayMethod(receiver, name, arguments, span, scope);
		if (library != null)
			return library;
		throw new MissingMember("E1007", 'Unknown array method "$name"', span);
	}

	/** Choose a raw collection operation without changing the nominal element checked at the call site. */
	function enumAbstractStorage(type:CompilerType):CompilerType
		return switch type {
			case TAbstract(owner, _,
				representation) if (session.enumAbstractDecls.exists(owner)): enumAbstractStorage(representation);
			default: type;
		};

	static function isDynamicType(type:CompilerType):Bool
		return switch type {
			case TDynamic: true;
			default: false;
		};

	/** `values.name(arguments)` as `haxeon.ArrayMethods.name(values, arguments)`, when the library defines it. */
	function typeLibraryArrayMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope):Null<TypedExpression> {
		if (!ArrayLibrary.provides(name))
			return null;
		var methodKey = ArrayLibrary.CLASS_NAME + "." + name,
			method = session.signatures.get(methodKey);
		if (method == null)
			return null;
		if (arguments.length + 1 > method.arguments.length)
			fail("E1008", 'Array.$name expects ${method.arguments.length - 1} arguments, got ${arguments.length}',
				span);
		var prepared = typeGenericCallArguments(method, arguments, scope, span, [receiver]);
		return genericInstantiation.specialize(methodKey, method, prepared.arguments, span, scope,
			ArrayLibrary.CLASS_NAME, true, prepared.substitutions);
	}

	function iterator(values:TypedExpression, element:CompilerType, span:SourceSpan):TypedExpression {
		// This becomes a typed IteratorNew IR operation. A Dynamic coercion can
		// replace an enum array with its erased view and lose the element type.
		return new TypedExpression(TCall("__iterator_new", [values]), TIterator(element), span);
	}

	public static function mapKeyIteratorSource(value:TypedExpression):Null<TypedExpression>
		return switch value.expression {
			case TCollectionCall(map, "keys", []): map;
			case TCall("__iterator_new", [source]), TToDynamic(source), TCast(source),
				TAbiCast(source): mapKeyIteratorSource(source);
			default: null;
		};

	public function typeIteratorMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan):TypedExpression {
		if (name != "hasNext" && name != "next")
			throw new MissingMember("E1007", 'Unknown Iterator method "$name"', span);
		if (arguments.length != 0)
			fail("E1008", 'Iterator.$name expects no arguments', span);
		return switch name {
			case "hasNext": new TypedExpression(TCall("__iterator_has_next", [receiver]), TBool, span);
			case "next":
				var element = switch receiver.type {
					case TIterator(value): value;
					default: throw new InternalError("Not an iterator");
				};
				new TypedExpression(TCall("__iterator_next", [receiver]), element, span);
			default: throw new InternalError('Unknown Iterator method "$name"');
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
						found = hasInstanceField(TInstance(NominalKind.Class, BodyTyper.inheritanceName(base), []),
							name);
				}
				found;
			default: false;
		};

	public function typeMapMethod(receiver:TypedExpression, name:String, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope):TypedExpression {
		var mapType = switch receiver.type {
			case TMap(key, value): {key: key, value: value};
			default: throw new InternalError("Not a map");
		};
		DeclaredConformance.requireMapRuntime(session, mapType.key, mapType.value, span);
		if (name == "set") {
			if (arguments.length != 2)
				fail("E1008", "Map.set expects a key and value", span);
			var key = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, mapType.key), mapType.key, "map key",
				"E1002"),
				value = bodyTyper.coerce(typeExpressionValue(arguments[1], scope, mapType.value), mapType.value,
					"map value",
					"E1002");
			var entryPath = FlowAnalysis.mapEntryPath(receiver, key);
			if (entryPath != null)
				scope.refineExpression(entryPath, mapType.value, FlowAnalysis.entryFactsSurviveCalls(scope, receiver));
			return new TypedExpression(TCollectionCall(receiver, "set", [key, value]), TVoid, span);
		}
		if (name == "copy") {
			if (arguments.length != 0)
				fail("E1008", "Map.copy expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "copy", []), receiver.type, span);
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
				scope.invalidateExpressionNamespaceCompletely(entriesPath);
			return new TypedExpression(TCollectionCall(receiver, "clear", []), TVoid, span);
		}
		if (name == "size") {
			if (arguments.length != 0)
				fail("E1008", "Map.size expects no arguments", span);
			return new TypedExpression(TCollectionCall(receiver, "size", []), TInt, span);
		}
		if (name != "exists" && name != "remove" && name != "get")
			throw new MissingMember("E1007", 'Unknown map method "$name"', span);
		if (arguments.length != 1)
			fail("E1008", 'Map.$name expects one argument', span);
		var key = bodyTyper.coerce(typeExpressionValue(arguments[0], scope, mapType.key), mapType.key, "map key",
			"E1002");
		return switch name {
			case "exists": new TypedExpression(TCollectionCall(receiver, "exists", [key]), TBool, span);
			case "remove":
				// Another key spelling may name the same entry, so removing any key forgets what is known about all of them.
				var entriesPath = FlowAnalysis.mapEntriesPath(receiver);
				if (entriesPath != null)
					scope.invalidateExpressionNamespaceCompletely(entriesPath);
				new TypedExpression(TCollectionCall(receiver, "remove", [key]), TBool, span);
			case "get":
				var entryPath = FlowAnalysis.mapEntryPath(receiver, key),
					refined = entryPath == null ? null : scope.resolveExpression(entryPath);
				new TypedExpression(TMapGet(receiver, key), refined == null ? nullableMapValue(mapType.value) : refined,
					span);
			default: throw new InternalError('Unknown map method "$name"');
		};
	}

	public static function nullableMapValue(type:CompilerType):CompilerType
		return switch type {
			case TNullable(_): type;
			default: TNullable(type);
		};

	public function typeInferredClassConstruction(typeName:String, arguments:Array<AstExpression>, span:SourceSpan,
			scope:Scope,
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
			while (required > 0 && AstPredicates.isOptionalArgument(constructor.arguments[required - 1]))
				required--;
			if (arguments.length < required || arguments.length > constructor.arguments.length) {
				var expected = required == constructor.arguments.length
					? '$required' : '$required to ${constructor.arguments.length}';
				fail("E1008", 'Function "$constructorName" expects $expected arguments, got ${arguments.length}', span);
			}
		}

		var typed:Array<TypedExpression> = [],
			constructor = hasConstructor ? requiredMapValue(session.signatures, constructorName) : null;
		for (index in 0...arguments.length) {
			var expectedArgument:Null<CompilerType> = null;
			if (allTypeParametersBound(parameters, substitutions) && constructor != null)
				expectedArgument = genericInstantiation.expectedArgumentType(constructor, index,
					constructor.arguments[index], substitutions);
			var argument = typeExpressionValue(arguments[index], scope, expectedArgument);
			if (constructor != null)
				genericInstantiation.inferArgumentTypeParameters(constructor, index, constructor.arguments[index],
					argument.type, parameters, substitutions, argument.span);
			typed.push(argument);
		}
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				fail("E1003", 'Cannot infer generic type parameter "$parameter" for constructor "$typeName"', span);
		validateTypeParameterConstraints(typeName, declaration.typeConstraints, substitutions, span);

		if (constructor != null) {
			var semanticExpected = bodyTyper.argumentTypesOf(constructor, substitutions);
			for (index in arguments.length...constructor.arguments.length) {
				var parameter = constructor.arguments[index],
					defaultValue = parameter.defaultValue;
				if (isPosInfosParameter(parameter))
					typed.push(typeExpressionValue(bodyTyper.posInfosExpression(span), scope, semanticExpected[index]));
				else if (defaultValue == null)
					typed.push(new TypedExpression(TNullLiteral, TNull, span));
				else
					typed.push(bodyTyper.typeDefaultExpression(parameter, semanticExpected[index], constructorName));
			}
			typed = coerceArguments(typed, semanticExpected, constructorName);
		}
		var typeArguments = [for (parameter in parameters) requiredMapValue(substitutions, parameter)],
			valueType = TInstance(NominalKind.Class, typeName, typeArguments),
			representationArguments = session.representation.adaptConstructorArguments(valueType, typeName, constructor,
				typed);
		return new TypedExpression(TNew(typeName, representationArguments, hasConstructor || implicitConstructor),
			valueType, span);
	}

	/** Resolves explicit and inferred class construction, including abstract constructors. */
	public function typeConstruction(typeName:String, typeArguments:Array<AstType>, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, hasExplicitTypeArguments:Bool):TypedExpression {
		MemberAccess.method(session, typeName, "new", span);
		if (session.declarations.abstracts.exists(typeName))
			return typeAbstractConstruction(typeName, typeArguments, arguments, span, scope, expectedType);
		if (hasExplicitTypeArguments) {
			if (!session.classDecls.exists(typeName) || session.interfaceDecls.exists(typeName))
				fail("E1007", 'Unknown class "$typeName"', span);
			var classDecl = requiredMapValue(session.classDecls, typeName),
				valueType = session.representation.semanticType(AppliedType(typeName, typeArguments), span,
					session.currentContext.typeSubstitutions),
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
				semanticArguments = constructor == null ? [] : typeDeclaredCallArguments(arguments,
					constructor, scope, constructorName, span,
					substitutions),
				typed = session.representation.adaptConstructorArguments(valueType, typeName, constructor,
					semanticArguments);
			return new TypedExpression(TNew(typeName, typed, hasConstructor || implicitConstructor), valueType, span);
		}
		if ((!session.classDecls.exists(typeName) && !PlatformAbi.isType(typeName))
			|| session.interfaceDecls.exists(typeName))
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
		var expected = hasConstructor ? bodyTyper.argumentTypesOf(requiredMapValue(session.signatures,
			constructorName)) : PlatformAbi.constructorArguments(typeName),
			resolvedExpected:Array<CompilerType> = [];
		if (expected != null)
			resolvedExpected = expected;
		if (!hasConstructor && arguments.length != resolvedExpected.length)
			fail("E1008",
				'Constructor "$typeName" expects ${resolvedExpected.length} arguments, got ${arguments.length}', span);
		var typed = hasConstructor ? typeDeclaredCallArguments(arguments,
			requiredMapValue(session.signatures, constructorName), scope,
			constructorName, span) : typeCallArguments(arguments, resolvedExpected, scope, constructorName),
			nativeConstructor = PlatformAbi.constructorNative(typeName),
			valueType = PlatformAbi.valueType(typeName);
		return nativeConstructor == null
			? new TypedExpression(TNew(typeName, typed, hasConstructor || implicitConstructor), valueType,
			span) : new TypedExpression(TCall(nativeConstructor, typed), valueType, span);
	}

	function typeAbstractConstruction(name:String, typeArguments:Array<AstType>, arguments:Array<AstExpression>,
			span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var decl = requiredMapValue(session.declarations.abstracts, name),
			constructorName = name + ".new",
			constructor = session.signatures.get(constructorName);
		if (constructor == null)
			fail("E1007", 'Abstract "$name" has no constructor', span);
		var inferred = typeArguments.length == 0
			&& decl.typeParameters.length > 0 ? inferAbstractConstruction(decl, constructor, arguments, span, scope,
			expectedType) : null,
			valueType = inferred != null ? inferred.type : typeArguments.length == 0
				? session.representation.semanticType(NamedType(name),
				span, session.currentContext.typeSubstitutions)
				: session.representation.semanticType(AppliedType(name, typeArguments), span,
				session.currentContext.typeSubstitutions);
		if (decl.isExtern == true) {
			var typed = typeDeclaredCallArguments(arguments, constructor, scope, constructorName, span);
			return new TypedExpression(TCall(constructorName, typed), valueType, span);
		}
		var substitutions = switch valueType {
			case TAbstract(_, appliedArguments, _):
				session.representation.typeParameterSubstitutions(decl.typeParameters, appliedArguments);
			default: new Map<String, CompilerType>();
		}, representation = session.representation.abstractUnderlying(valueType);
		var normalized = AbstractConstructorNormalizer.normalize(constructor, decl.underlying),
			table = session.types;
		if (table != null)
			table.alias(normalized, constructor);
		var typedArguments = inferred != null ? inferred.arguments : [
			for (argument in arguments)
				bodyTyper.typeExpression(argument, scope)
		],
			constructed:TypedExpression;
		try {
			constructed = genericInstantiation.specialize(constructorName, normalized, typedArguments, span, scope,
				name, true, substitutions);
		} catch (error:CompileError) {
			throw AbstractConstructorNormalizer.constructorError(error, constructorName);
		}
		return session.representation.boundaryCast(bodyTyper.coerce(constructed, representation,
			'abstract constructor "$constructorName"', "E1003"), valueType);
	}

	/**
	 * `new Box(values)` of a generic abstract without type arguments: as Haxe infers them, from the arguments, typed against the
	 * constructor's arguments once those before bind them; a parameter they leave open takes the expected type's
	 * (`var b:Box<Int> = new Box(...)`). The expected type does not steer the arguments: `var b:Box<Float> = new Box([1])` is an
	 * error, as in Haxe.
	 */
	function inferAbstractConstruction(decl:compiler.syntax.Ast.AstAbstract, constructor:AstFunction,
			arguments:Array<AstExpression>, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>):{
				type:CompilerType,
				arguments:Array<TypedExpression>
			} {
		var parameters = decl.typeParameters, substitutions:Map<String, CompilerType> = [];
		var typed:Array<TypedExpression> = [];
		for (index in 0...arguments.length) {
			var declared = index < constructor.arguments.length ? constructor.arguments[index] : null,
				expectedArgument = declared != null
					&& allTypeParametersBound(parameters, substitutions)
					? genericInstantiation.expectedArgumentType(constructor,
					index, declared, substitutions) : null,
				argument = bodyTyper.typeExpression(arguments[index], scope, expectedArgument);
			if (declared != null)
				genericInstantiation.inferArgumentTypeParameters(constructor, index, declared, argument.type,
					parameters,
					substitutions, argument.span);
			typed.push(argument);
		}
		switch expectedType {
			case TAbstract(expectedName, values, _),
				TNullable(TAbstract(expectedName, values, _)) if (expectedName == decl.name):
				for (index in 0...parameters.length)
					if (index < values.length) {
						var inferred = substitutions.get(parameters[index]);
						if (inferred == null)
							substitutions.set(parameters[index], values[index]);
						else if (Monomorphs.follow(inferred).match(TMonomorph(_))) {
							// An argument that left it open (`[]`) takes it, as a type variable unifies.
							Monomorphs.unify(inferred, values[index]);
							substitutions.set(parameters[index], Monomorphs.resolve(inferred));
						}
					}
			default:
		}
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				fail("E1003", 'Cannot infer generic type parameter "$parameter" for constructor "${decl.name}"', span);
		validateTypeParameterConstraints(decl.name, decl.typeConstraints, substitutions, span);
		return {
			type: TAbstract(decl.name, [for (parameter in parameters) requiredMapValue(substitutions, parameter)],
				session.representation.semanticType(decl.underlying, decl.span, substitutions)),
			arguments: typed
		};
	}

	static function allTypeParametersBound(parameters:Array<String>, substitutions:Map<String, CompilerType>):Bool {
		for (parameter in parameters)
			if (!substitutions.exists(parameter))
				return false;
		return true;
	}

	function validateTypeParameterConstraints(name:String, constraints:Null<Array<AstTypeConstraint>>,
			substitutions:Map<String, CompilerType>,
			span:SourceSpan):Void {
		if (constraints == null)
			return;
		for (constraint in constraints) {
			var actual = requiredMapValue(substitutions, constraint.parameter),
				expected = session.declarations.resolve(constraint.type, constraint.span, substitutions);
			if ((switch (actual) {
				case TDynamic: true;
				default: false;
			}))
				fail("E1003",
				'Cannot construct "$name" with Dynamic for constrained type parameter "${constraint.parameter}"; its conformance must be known',
				span);
			if (!session.relations.satisfiesConstraint(actual, expected)) {
				var detail = session.relations.constraintFailure(actual, expected);
				fail(session.relations.recursiveCapabilityFailure(actual, expected) ? "E1025" : "E1003",
					'Type argument for "${constraint.parameter}" on "$name" does not satisfy constraint "${SemanticSignature.type(expected)}"'
					+ (detail == null ? "" : ': $detail'),
					span);
			}
		}
	}

	static function requiredMapValue<T>(source:Map<String, T>, name:String):T {
		if (!source.exists(name))
			throw new InternalError('Missing map entry "$name"');
		return source.get(name);
	}

	public static function isPosInfosParameter(argument:AstArgument):Bool
		return argument.optional == true && switch argument.type {
			case NamedType("haxe.PosInfos"): true;
			default: false;
		};

	@:noReturn
	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));

	/**
	 * `pop` and `shift` as Haxe types them: `Null<T>`, null when the array is empty (the runtime operation itself requires an
	 * element). The receiver is evaluated once.
	 */
	function takeOrNull(receiver:TypedExpression, element:CompilerType, take:TypedExpression->TypedExpression,
			span:SourceSpan):TypedExpression {
		var resultType:CompilerType = switch element {
			case TNullable(_): element;
			default: TNullable(element);
		};
		var id = '$' + 'array-take:${session.currentContext.arrayTakeTemporary++}',
			array = new TypedExpression(TLocal(id), receiver.type, span),
			empty = new TypedExpression(TEqual(new TypedExpression(TArrayLength(array), TInt, span),
				new TypedExpression(TIntLiteral(0), TInt, span)), TBool,
				span),
			taken = take(array),
			present = taken.type.match(TNullable(_)) ? taken : new TypedExpression(TNullableWrap(taken), resultType,
				span),
			nothing = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), resultType,
				span);
		return new TypedExpression(TBlockExpression([TVar(id, receiver, span)],
			new TypedExpression(TConditional(empty, nothing, present), resultType, span)),
			resultType, span);
	}
}
