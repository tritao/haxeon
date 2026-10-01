package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.runtime.RuntimeType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.typing.TypingSession.EqualityRequest;
import haxe.crypto.Sha256;

/** Generates structural comparisons for the statically known type at each call site. */
class EqualityGenerator {
	public static function equalsName(type:CompilerType):String {
		// Std.string would never finish on a structure that contains itself; its spelling names such a structure instead.
		var spelling = compiler.semantic.SemanticSignature.type(type);
		return "$equality:" + Sha256.encode(spelling.indexOf("$anon:rec:") >= 0 ? spelling : Std.string(type)).substr(0, 32);
	}

	public static function request(session:TypingSession, type:CompilerType, origin:String, span:SourceSpan):Void {
		var key = equalsName(type);
		if (!session.equalityRequests.exists(key))
			session.equalityRequests.set(key, {type: type, origin: origin, span: span});
	}

	public static function generate(session:TypingSession):Array<TypedFunction> {
		var reachable:Map<String, CompilerType> = [],
			requests:Map<String, EqualityRequest> = [],
			requestKeys = [for (key in session.equalityRequests.keys()) key];
		requestKeys.sort(Reflect.compare);
		// Direct requests first, so a helper someone asked for keeps that caller as its origin.
		for (key in requestKeys)
			requests.set(key, session.equalityRequests.get(key));
		for (key in requestKeys)
			collect(session, requests.get(key).type, requests.get(key), reachable, requests);
		var keys = [for (key in reachable.keys()) key];
		keys.sort(Reflect.compare);
		return [
			for (key in keys)
				compareFunction(session, reachable.get(key), requests.get(key))
		];
	}

	/**
	 * Collects every helper a comparison of `type` needs. A helper reached only through another one takes the
	 * origin of the request that reached it: incremental builds keep a generated function while its origin is
	 * unchanged, so the nested helper then lives exactly as long as the helper calling it.
	 */
	static function collect(session:TypingSession, type:CompilerType, root:EqualityRequest, reachable:Map<String, CompilerType>,
			requests:Map<String, EqualityRequest>):Void {
		var key = equalsName(type), span = root.span;
		if (reachable.exists(key))
			return;
		reachable.set(key, type);
		if (!requests.exists(key))
			requests.set(key, {type: type, origin: root.origin, span: root.span});
		switch type {
			case TInt, TInt64, TFloat, TBool, TString, TBytes, TNull:
			case TAbstract(_, _, representation):
				collect(session, representation, root, reachable, requests);
			case TNullable(element):
				collect(session, element, root, reachable, requests);
			case TArray(element):
				if (RuntimeType.arrayName(element) == null)
					unsupported(type, span);
				collect(session, element, root, reachable, requests);
			case TMap(keyType, valueType):
				if (RuntimeType.mapName(keyType, valueType) == null || !supportedMapKey(session, keyType))
					unsupported(type, span);
				collect(session, valueType, root, reachable, requests);
			case TAnonymous(_, fields):
				for (field in fields)
					collect(session, field.type, root, reachable, requests);
			case TInstance(NominalKind.Enum, name, arguments):
				var declaration = session.enumDecls.get(name);
				if (declaration == null || declaration.typeParameters.length != arguments.length)
					unsupported(type, span);
				for (constructor in declaration.cases)
					for (parameter in constructor.params)
						collect(session, session.representation.enumParameterType(declaration.typeParameters, parameter, type), root, reachable, requests);
			default:
				unsupported(type, span);
		}
	}

	static function supportedMapKey(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TInt, TString: true;
			case TInstance(NominalKind.Enum, name, arguments):
				var declaration = session.enumDecls.get(name);
				if (declaration == null || arguments.length != 0) false; else {
					var nullary = true;
					for (constructor in declaration.cases)
						if (constructor.params.length != 0)
							nullary = false;
					nullary;
				}
			default: false;
		};

	static function unsupported(type:CompilerType, span:SourceSpan):Void
		BodyTyper.fail("E1025", 'Structural equality does not support type "$type"', span);

	static function compareFunction(session:TypingSession, type:CompilerType, request:EqualityRequest):TypedFunction {
		var span = request.span,
			left = local("left", type, span),
			right = local("right", type, span),
			statements = compareStatements(session, type, left, right, span);
		return {
			name: equalsName(type),
			genericOrigin: request.origin,
			typeArguments: null,
			owner: null,
			isStatic: true,
			isConstructor: false,
			arguments: [{name: "left", type: type}, {name: "right", type: type}],
			result: TBool,
			statements: statements,
			cells: [],
			cellCaptures: [],
			span: span
		};
	}

	static function compareStatements(session:TypingSession, type:CompilerType, left:TypedExpression, right:TypedExpression,
			span:SourceSpan):Array<TypedStatement> {
		return switch type {
			case TInt, TInt64, TFloat, TBool, TString:
				[TReturn(equal(left, right, span), span)];
			case TAbstract(_, _, representation):
				[
					TReturn(call(representation, session.representation.boundaryCast(left, representation),
						session.representation.boundaryCast(right, representation), span),
						span)
				];
			case TBytes:
				[
					TReturn(equal(new TypedExpression(TCall("__bytes_compare", [left, right]), TInt, span), integer(0, span), span), span)
				];
			case TNull:
				[TReturn(bool(true, span), span)];
			case TNullable(element):
				var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span);
				[
					TIf(equal(left, nil, span), [TReturn(equal(right, nil, span), span)], [], span),
					TIf(equal(right, nil, span), [TReturn(bool(false, span), span)], [], span),
					TReturn(call(element, castValue(left, element), castValue(right, element), span), span)
				];
			case TArray(element):
				var length = new TypedExpression(TArrayLength(left), TInt, span),
					otherLength = new TypedExpression(TArrayLength(right), TInt, span),
					index = local("__equality_index", TInt, span),
					leftElement = new TypedExpression(TIndex(left, index), element, span),
					rightElement = new TypedExpression(TIndex(right, index), element, span);
				referenceGuards(type, left, right, span).concat([
					ifFalse(equal(length, otherLength, span), span),
					TVar("__equality_index", integer(0, span), span),
					TWhile(new TypedExpression(TLess(index, length), TBool, span), [
						ifFalse(call(element, leftElement, rightElement, span), span),
						TAssign("__equality_index", new TypedExpression(TAdd(index, integer(1, span)), TInt, span), span)
					], span),
					TReturn(bool(true, span), span)
				]);
			case TMap(keyType, valueType):
				var key = local("__equality_key", keyType, span),
					leftSize = new TypedExpression(TCollectionCall(left, "size", []), TInt, span),
					rightSize = new TypedExpression(TCollectionCall(right, "size", []), TInt, span),
					keys = new TypedExpression(TCollectionCall(left, "keys", []), TArray(keyType), span),
					exists = new TypedExpression(TCollectionCall(right, "exists", [key]), TBool, span),
					leftValue = new TypedExpression(TMapGet(left, key), valueType, span),
					rightValue = new TypedExpression(TMapGet(right, key), valueType, span);
				referenceGuards(type, left, right, span).concat([
					ifFalse(equal(leftSize, rightSize, span), span),
					TForIn("__equality_key", null, keys, [
						ifFalse(exists, span),
						ifFalse(call(valueType, leftValue, rightValue, span), span)
					], span),
					TReturn(bool(true, span), span)
				]);
			case TAnonymous(_, fields):
				var result:Array<TypedStatement> = referenceGuards(type, left, right, span);
				for (field in fields)
					result.push(ifFalse(call(field.type, new TypedExpression(TField(left, field.name), field.type, span),
						new TypedExpression(TField(right, field.name), field.type, span), span),
						span));
				result.push(TReturn(bool(true, span), span));
				result;
			case TInstance(NominalKind.Enum, name, _):
				var declaration = session.enumDecls.get(name),
					leftIndex = new TypedExpression(TEnumIndex(left), TInt, span),
					rightIndex = new TypedExpression(TEnumIndex(right), TInt, span),
					result:Array<TypedStatement> = referenceGuards(type, left, right, span);
				if (declaration == null)
					throw 'Missing enum declaration "$name"';
				result.push(ifFalse(equal(leftIndex, rightIndex, span), span));
				for (constructorIndex in 0...declaration.cases.length) {
					var constructor = declaration.cases[constructorIndex],
						body:Array<TypedStatement> = [];
					for (fieldIndex in 0...constructor.params.length) {
						var parameter = constructor.params[fieldIndex],
							parameterType = session.representation.enumParameterType(declaration.typeParameters, parameter, type),
							storageType = session.representation.enumStorageType(declaration.typeParameters, parameter),
							leftField = session.representation.boundaryCast(new TypedExpression(TEnumField(left, constructorIndex, fieldIndex), storageType,
								span), parameterType),
							rightField = session.representation.boundaryCast(new TypedExpression(TEnumField(right, constructorIndex, fieldIndex), storageType,
								span), parameterType);
						body.push(ifFalse(call(parameterType, leftField, rightField, span), span));
					}
					body.push(TReturn(bool(true, span), span));
					result.push(TIf(equal(leftIndex, integer(constructorIndex, span), span), body, [], span));
				}
				result.push(TReturn(bool(false, span), span));
				result;
			default:
				throw 'No structural equality generator for "$type"';
		};
	}

	static function referenceGuards(type:CompilerType, left:TypedExpression, right:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		var nil = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span);
		return [
			TIf(new TypedExpression(TCall("__reference_equal", [left, right]), TBool, span), [TReturn(bool(true, span), span)], [], span),
			TIf(equal(left, nil, span), [TReturn(bool(false, span), span)], [], span),
			TIf(equal(right, nil, span), [TReturn(bool(false, span), span)], [], span)
		];
	}

	static function ifFalse(condition:TypedExpression, span:SourceSpan):TypedStatement
		return TIf(new TypedExpression(TNot(condition), TBool, span), [TReturn(bool(false, span), span)], [], span);

	static function call(type:CompilerType, left:TypedExpression, right:TypedExpression, span:SourceSpan):TypedExpression
		return new TypedExpression(TCall(equalsName(type), [left, right]), TBool, span);

	static function equal(left:TypedExpression, right:TypedExpression, span:SourceSpan):TypedExpression
		return new TypedExpression(TEqual(left, right), TBool, span);

	static function castValue(value:TypedExpression, type:CompilerType):TypedExpression
		return new TypedExpression(TCast(value), type, value.span);

	static function local(name:String, type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TLocal(name), type, span);

	static function integer(value:Int, span:SourceSpan):TypedExpression
		return new TypedExpression(TIntLiteral(value), TInt, span);

	static function bool(value:Bool, span:SourceSpan):TypedExpression
		return new TypedExpression(TBoolLiteral(value), TBool, span);
}
