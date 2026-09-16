package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedEnumCase;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedField;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypeRelations;
import compiler.types.typing.TypingSession.WireCodecRequest;

private typedef WireField = {
	final field:TypedField;
	final id:Int;
}

private typedef WireEnumCase = {
	final caseDecl:TypedEnumCase;
	final index:Int;
	final id:Int;
}

/** Emits the first compiler-owned MessagePack codec profile. */
class WireCodecGenerator {
	static inline final ENCODE_PREFIX:String = "$wire:encode:";
	static inline final DECODE_PREFIX:String = "$wire:decode:";
	static inline final VALUE_ENCODE_PREFIX:String = "$wire:value-encode:";
	static inline final VALUE_DECODE_PREFIX:String = "$wire:value-decode:";
	static inline final INT_COMPARE_NAME:String = "$wire:map-int-compare";
	static inline final WRITER:String = "haxe.wire.MessagePackWriter";
	static inline final READER:String = "haxe.wire.MessagePackReader";
	static inline final DEFAULT_MAX_BYTES:Int = 16 * 1024 * 1024;
	static inline final DEFAULT_MAX_CONTAINER:Int = 1000000;
	static inline final DEFAULT_MAX_DEPTH:Int = 64;

	/** Register one source-level encode/decode request for later code generation. */
	public static function request(session:TypingSession, type:CompilerType, origin:String, span:SourceSpan):Void {
		if (!isRequestType(session, type))
			BodyTyper.fail("E1024", 'MessagePack does not support type "$type" in the current wire profile', span);
		var key = typeKey(type);
		if (!session.wireCodecRequests.exists(key))
			session.wireCodecRequests.set(key, {type: type, origin: origin, span: span});
	}

	/** Generate wrappers and value codecs requested while typing source bodies. */
	public static function generate(session:TypingSession, classes:Array<TypedClass>, enums:Array<TypedEnum>):Array<TypedFunction> {
		var classesByName:Map<String, TypedClass> = [];
		for (classDecl in classes)
			classesByName.set(classDecl.name, classDecl);
		var enumsByName:Map<String, TypedEnum> = [];
		for (enumDecl in enums)
			enumsByName.set(enumDecl.name, enumDecl);
		var roots:Array<WireCodecRequest> = [
			for (key in session.wireCodecRequests.keys())
				cast session.wireCodecRequests.get(key)
		];
		roots.sort(function(left, right) return Reflect.compare(typeKey(left.type), typeKey(right.type)));
		var reachable:Map<String, CompilerType> = [],
			requests:Map<String, WireCodecRequest> = [],
			rootKeys:Map<String, Bool> = [],
			visiting:Map<String, Bool> = [],
			path:Array<String> = [];
		for (request in roots) {
			var key = typeKey(request.type);
			requests.set(key, request);
			rootKeys.set(key, true);
			collectType(session, request.type, classesByName, enumsByName, reachable, visiting, path, request.span);
		}
		var keys = [for (key in reachable.keys()) key];
		keys.sort(Reflect.compare);
		var result:Array<TypedFunction> = [];
		var needsIntComparator = false;
		for (key in keys) {
			var type = reachable.get(key), request = requests.get(key);
			if (request == null)
				request = {type: type, origin: roots[0].origin, span: roots[0].span};
			if (switch type {
					case TMap(TInt, _): true;
					default: false;
				})
				needsIntComparator = true;
			result.push(valueEncoder(session, type, classesByName, enumsByName, request));
			result.push(valueDecoder(session, type, classesByName, enumsByName, request));
			if (rootKeys.exists(key)) {
				result.push(encoder(type, request));
				result.push(decoder(type, request));
			}
		}
		if (needsIntComparator)
			result.push(intComparator(roots[0]));
		return result;
	}

	public static function encodeName(type:CompilerType):String
		return ENCODE_PREFIX + typeKey(type);

	public static function decodeName(type:CompilerType):String
		return DECODE_PREFIX + typeKey(type);

	static function valueEncodeName(type:CompilerType):String
		return VALUE_ENCODE_PREFIX + typeKey(type);

	static function valueDecodeName(type:CompilerType):String
		return VALUE_DECODE_PREFIX + typeKey(type);

	static function isRequestType(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TInt, TFloat, TBool, TString, TBytes: true;
			case TNullable(element): isRequestType(session, element);
			case TArray(element): isRequestType(session, element);
			case TMap(TString, value): isRequestType(session, value);
			case TMap(TInt, value): isRequestType(session, value);
			case TInstance(NominalKind.Class, name, arguments): arguments.length == 0 && isWireClass(session, name);
			case TInstance(NominalKind.Enum, name, arguments): arguments.length == 0 && isWireEnum(session, name);
			default: false;
		};

	static function collectType(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			reachable:Map<String, CompilerType>, visiting:Map<String, Bool>, path:Array<String>, span:SourceSpan):Void {
		if (!isRequestType(session, type))
			BodyTyper.fail("E1024", 'MessagePack does not support type "$type" in the current wire profile', span);
		var key = typeKey(type);
		if (reachable.exists(key))
			return;
		if (visiting.exists(key)) {
			var schemaKind = switch type {
				case TInstance(NominalKind.Enum, _, _): "enum";
				default: "record";
			};
			BodyTyper.fail("E1024", 'MessagePack $schemaKind schema cannot be recursive (${path.concat([key]).join(" -> ")})', span);
		}
		visiting.set(key, true);
		path.push(key);
		switch type {
			case TNullable(element):
				collectType(session, element, classes, enums, reachable, visiting, path, span);
			case TArray(element):
				collectType(session, element, classes, enums, reachable, visiting, path, span);
			case TMap(_, value):
				collectType(session, value, classes, enums, reachable, visiting, path, span);
			case TInstance(NominalKind.Class, name, _):
				var declaration = classes.get(name);
				if (declaration == null)
					BodyTyper.fail("E1024", 'MessagePack record "$name" is not available in the typed program', span);
				if (declaration.base != null)
					BodyTyper.fail("E1024", 'MessagePack record "$name" cannot extend another class yet', declaration.span);
				var fields = serializableFields(session, declaration, span);
				if (fields.length == 0)
					BodyTyper.fail("E1024", 'MessagePack record "$name" must declare at least one instance field', declaration.span);
				for (wireField in fields)
					collectType(session, wireField.field.type, classes, enums, reachable, visiting, path, wireField.field.span);
			case TInstance(NominalKind.Enum, name, _):
				var declaration = requiredEnum(enums, name, span),
					cases = wireEnumCases(declaration, span);
				if (cases.length == 0)
					BodyTyper.fail("E1024", 'MessagePack enum "$name" must declare at least one constructor', declaration.span);
				for (wireCase in cases)
					for (parameter in wireCase.caseDecl.params)
						collectType(session, parameter, classes, enums, reachable, visiting, path, wireCase.caseDecl.span);
			default:
		}
		path.pop();
		visiting.remove(key);
		reachable.set(key, type);
	}

	static function serializableFields(session:TypingSession, declaration:TypedClass, span:SourceSpan):Array<WireField> {
		var result:Array<WireField> = [], ids:Map<Int, TypedField> = [];
		for (field in declaration.fields) {
			if (field.isStatic)
				continue;
			if (field.initializer != null)
				BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" cannot have an initializer yet', field.span);
			if (field.isFinal)
				BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" cannot be final yet', field.span);
			if (!hasDirectStorage(field))
				BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" must have direct storage', field.span);
			if (!isRequestType(session, field.type))
				BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" has unsupported type "${field.type}"', field.span);
			var id = wireFieldId(declaration, field);
			if (ids.exists(id))
				BodyTyper.fail("E1024",
					'MessagePack record fields "${declaration.name}.${ids.get(id).name}" and "${declaration.name}.${field.name}" use duplicate @:wireId($id)',
					field.span);
			ids.set(id, field);
			result.push({field: field, id: id});
		}
		result.sort(function(left, right) return Reflect.compare(left.id, right.id));
		return result;
	}

	static function wireFieldId(declaration:TypedClass, field:TypedField):Int {
		var id:Null<Int> = null;
		for (metadata in field.metadata) {
			if (metadata.name != "wireId")
				continue;
			if (id != null)
				BodyTyper.fail("E1024", 'MessagePack record field "${field.name}" cannot declare @:wireId more than once', metadata.span);
			if (metadata.arguments.length != 1)
				BodyTyper.fail("E1024", '@:wireId requires exactly one integer argument', metadata.span);
			switch metadata.arguments[0] {
				case compiler.syntax.Ast.AstExpression.IntegerLiteral(value, _):
					id = value;
				default:
					BodyTyper.fail("E1024", '@:wireId requires an integer literal argument', metadata.span);
			}
		}
		if (id == null)
			BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" requires @:wireId(n)', field.span);
		if (id <= 0)
			BodyTyper.fail("E1024", '@:wireId must be a positive integer', field.span);
		return cast id;
	}

	static function wireEnumCases(declaration:TypedEnum, span:SourceSpan):Array<WireEnumCase> {
		var result:Array<WireEnumCase> = [], ids:Map<Int, TypedEnumCase> = [];
		for (index in 0...declaration.cases.length) {
			var caseDecl = declaration.cases[index];
			var id = wireEnumCaseId(declaration, caseDecl);
			if (ids.exists(id))
				BodyTyper.fail("E1024",
					'MessagePack enum "${declaration.name}" constructors "${ids.get(id).name}" and "${caseDecl.name}" use duplicate @:wireId($id)',
					caseDecl.span);
			ids.set(id, caseDecl);
			result.push({caseDecl: caseDecl, index: index, id: id});
		}
		return result;
	}

	static function wireEnumCaseId(declaration:TypedEnum, caseDecl:TypedEnumCase):Int {
		var id:Null<Int> = null;
		for (metadata in caseDecl.metadata) {
			if (metadata.name != "wireId")
				continue;
			if (id != null)
				BodyTyper.fail("E1024", 'MessagePack enum constructor "${caseDecl.name}" cannot declare @:wireId more than once', metadata.span);
			if (metadata.arguments.length != 1)
				BodyTyper.fail("E1024", '@:wireId requires exactly one integer argument', metadata.span);
			switch metadata.arguments[0] {
				case compiler.syntax.Ast.AstExpression.IntegerLiteral(value, _):
					id = value;
				default:
					BodyTyper.fail("E1024", '@:wireId requires an integer literal argument', metadata.span);
			}
		}
		if (id == null)
			BodyTyper.fail("E1024", 'MessagePack enum constructor "${declaration.name}.${caseDecl.name}" requires @:wireId(n)', caseDecl.span);
		if (id <= 0)
			BodyTyper.fail("E1024", '@:wireId must be a positive integer', caseDecl.span);
		return cast id;
	}

	static function intComparator(request:WireCodecRequest):TypedFunction {
		var left = local("left", TInt, request.span),
			right = local("right", TInt, request.span),
			result = new TypedExpression(TConditional(new TypedExpression(TLess(left, right), TBool, request.span), intLiteral(-1, request.span),
				new TypedExpression(TConditional(new TypedExpression(TLess(right, left), TBool, request.span), intLiteral(1, request.span),
					intLiteral(0, request.span)),
					TInt, request.span)),
				TInt, request.span);
		return generatedFunction(INT_COMPARE_NAME, [{name: "left", type: TInt}, {name: "right", type: TInt}], TInt, [TReturn(result, request.span)], request);
	}

	static function mapKeyComparator(type:CompilerType, span:SourceSpan):TypedExpression
		return switch type {
			case TString: new TypedExpression(TFunctionRef("__string_compare_full"), TFunction([TString, TString], TInt), span);
			case TInt: new TypedExpression(TFunctionRef(INT_COMPARE_NAME), TFunction([TInt, TInt], TInt), span);
			default: throw 'No MessagePack map key comparator for "$type"';
		};

	static function valueEncoder(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			request:WireCodecRequest):TypedFunction {
		var writerType = classType(WRITER),
			valueType = type,
			writer = local("writer", writerType, request.span),
			value = local("value", valueType, request.span),
			statements = encodeValueStatements(session, classes, enums, writer, value, type, request.span);
		return generatedFunction(valueEncodeName(type), [{name: "writer", type: writerType}, {name: "value", type: valueType}], TVoid, statements, request);
	}

	static function encodeValueStatements(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>, writer:TypedExpression,
			value:TypedExpression, type:CompilerType, span:SourceSpan):Array<TypedStatement> {
		return switch type {
			case TNullable(element):
				var nonNullValue = new TypedExpression(TCast(value), element, value.span);
				[
					TIf(isNullValue(value, type, span), [expressionStatement(method(writer, "writeNil", [], TVoid, span), span)],
						encodeNestedValueStatements(writer, nonNullValue, element, span), span)
				];
			case TArray(element):
				var indexName = "__wire_array_index",
					arrayLength = new TypedExpression(TArrayLength(value), TInt, span),
					index = local(indexName, TInt, span),
					result:Array<TypedStatement> = [
						expressionStatement(method(writer, "writeArrayHeader", [arrayLength], TVoid, span), span),
						TVar(indexName, intLiteral(0, span), span)
					];
				result.push(TWhile(new TypedExpression(TLess(index, arrayLength), TBool, span), [
					expressionStatement(new TypedExpression(TCall(valueEncodeName(element),
						[writer, new TypedExpression(TIndex(value, index), element, span)]), TVoid, span),
						span),
					TAssign(indexName, new TypedExpression(TAdd(index, intLiteral(1, span)), TInt, span), span)
				], span));
				result;
			case TMap(keyType, valueType):
				var keysType = TArray(keyType),
					keysName = "__wire_map_keys",
					keyName = "__wire_map_key",
					indexName = "__wire_map_index",
					keys = local(keysName, keysType, span),
					key = local(keyName, keyType, span),
					index = local(indexName, TInt, span),
					keysExpression = new TypedExpression(TCollectionCall(value, "keys", []), keysType, span),
					comparator = mapKeyComparator(keyType, span),
					result:Array<TypedStatement> = [
						TVar(keysName, new TypedExpression(TNewArray(keyType, intLiteral(0, span)), keysType, span), span),
						TForIn(keyName, null, keysExpression, [
							expressionStatement(new TypedExpression(TArrayPush(keys, key), TInt, span), span)
						],
							span),
						expressionStatement(new TypedExpression(TArraySort(keys, comparator), TVoid, span), span),
						expressionStatement(method(writer, "writeMapHeader", [new TypedExpression(TArrayLength(keys), TInt, span)], TVoid, span), span),
						TVar(indexName, intLiteral(0, span), span)
					];
				var mapKey = new TypedExpression(TIndex(keys, index), keyType, span);
				result.push(TWhile(new TypedExpression(TLess(index, new TypedExpression(TArrayLength(keys), TInt, span)), TBool, span), [
					expressionStatement(method(writer, mapKeyMethod(keyType, true), [mapKey], TVoid, span), span),
					expressionStatement(new TypedExpression(TCall(valueEncodeName(valueType),
						[writer, new TypedExpression(TMapGet(value, mapKey), valueType, span)]), TVoid, span),
						span),
					TAssign(indexName, new TypedExpression(TAdd(index, intLiteral(1, span)), TInt, span), span)
				], span));
				result;
			case TInstance(NominalKind.Class, name, _):
				var declaration = requiredClass(classes, name, span),
					fields = serializableFields(session, declaration, span),
					result:Array<TypedStatement> = [
						expressionStatement(method(writer, "writeMapHeader", [intLiteral(fields.length, span)], TVoid, span), span)
					];
				for (wireField in fields) {
					var field = wireField.field,
						fieldValue = new TypedExpression(TField(value, field.name), field.type, field.span);
					result.push(expressionStatement(method(writer, "writeInt", [intLiteral(wireField.id, span)], TVoid, span), span));
					result = result.concat(encodeNestedValueStatements(writer, fieldValue, field.type, field.span));
				}
				result;
			case TInstance(NominalKind.Enum, name, _):
				var declaration = requiredEnum(enums, name, span),
					cases = wireEnumCases(declaration, span),
					result:Array<TypedStatement> = [
						expressionStatement(method(writer, "writeMapHeader", [intLiteral(1, span)], TVoid, span), span)
					],
					fallback:Array<TypedStatement> = [
						TThrow(stringLiteral('Unknown MessagePack constructor for enum "$name"', span), span)
					];
				for (caseIndex in 0...cases.length) {
					var wireCase = cases[cases.length - caseIndex - 1],
						branch:Array<TypedStatement> = [
							expressionStatement(method(writer, "writeInt", [intLiteral(wireCase.id, span)], TVoid, span), span),
							expressionStatement(method(writer, "writeArrayHeader", [intLiteral(wireCase.caseDecl.params.length, span)], TVoid, span), span)
						];
					for (fieldIndex in 0...wireCase.caseDecl.params.length) {
						var parameterType = wireCase.caseDecl.params[fieldIndex],
							fieldValue = new TypedExpression(TEnumField(value, wireCase.index, fieldIndex), parameterType, span);
						branch = branch.concat(encodeNestedValueStatements(writer, fieldValue, parameterType, span));
					}
					var condition = new TypedExpression(TEqual(new TypedExpression(TEnumIndex(value), TInt, span), intLiteral(wireCase.index, span)), TBool,
						span);
					fallback = [TIf(condition, branch, fallback, span)];
				}
				result.concat(fallback);
			default:
				var methodName = primitiveMethod(type);
				if (methodName == null)
					throw 'No MessagePack encoder for "$type"';
				[expressionStatement(method(writer, methodName, [value], TVoid, span), span)];
		};
	}

	static function encodeNestedValueStatements(writer:TypedExpression, value:TypedExpression, type:CompilerType, span:SourceSpan):Array<TypedStatement>
		return [
			expressionStatement(new TypedExpression(TCall(valueEncodeName(type), [writer, value]), TVoid, span), span)
		];

	static function valueDecoder(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			request:WireCodecRequest):TypedFunction {
		var readerType = classType(READER),
			reader = local("reader", readerType, request.span),
			statements:Array<TypedStatement> = [];
		switch type {
			case TNullable(element):
				var decoded = decodeValueExpression(session, classes, enums, reader, element, request.span),
					wrapped = new TypedExpression(TNullableWrap(decoded), type, request.span);
				statements.push(TIf(method(reader, "isNil", [], TBool, request.span), [
					expressionStatement(method(reader, "readNil", [], TVoid, request.span), request.span),
					TReturn(nullValue(type, request.span), request.span)
				], [TReturn(wrapped, request.span)], request.span));
			case TInstance(NominalKind.Class, name, _):
				var declaration = requiredClass(classes, name, request.span),
					fields = serializableFields(session, declaration, request.span),
					countName = "__wire_count",
					indexName = "__wire_index",
					keyName = "__wire_key",
					resultName = "__wire_result";
				statements.push(TVar(countName, method(reader, "readMapHeader", [], TInt, request.span), request.span));
				statements.push(TVar(indexName, intLiteral(0, request.span), request.span));
				for (index in 0...fields.length)
					statements.push(TVar(fieldLocal(index), defaultValue(fields[index].field.type, enums, request.span), request.span));
				statements.push(TWhile(new TypedExpression(TLess(local(indexName, TInt, request.span), local(countName, TInt, request.span)), TBool,
					request.span),
					decodeMapBody(session, classes, enums, fields, reader, keyName, request.span), request.span));
				var resultType = type,
					newValue = new TypedExpression(TNew(name, [], false), resultType, request.span);
				statements.push(TVar(resultName, newValue, request.span));
				for (index in 0...fields.length)
					statements.push(TFieldAssign(local(resultName, resultType, request.span), fields[index].field.name,
						local(fieldLocal(index), fields[index].field.type, request.span), request.span));
				statements.push(TReturn(local(resultName, resultType, request.span), request.span));
			case TArray(element):
				var countName = "__wire_count",
					indexName = "__wire_index",
					resultName = "__wire_result",
					resultType = TArray(element);
				statements.push(TVar(countName, method(reader, "readArrayHeader", [], TInt, request.span), request.span));
				statements.push(TVar(indexName, intLiteral(0, request.span), request.span));
				statements.push(TVar(resultName, new TypedExpression(TNewArray(element, local(countName, TInt, request.span)), resultType, request.span),
					request.span));
				statements.push(TWhile(new TypedExpression(TLess(local(indexName, TInt, request.span), local(countName, TInt, request.span)), TBool,
					request.span),
					decodeArrayBody(session, classes, enums, resultName, resultType, element, reader, indexName, request.span), request.span));
				statements.push(TReturn(local(resultName, resultType, request.span), request.span));
			case TMap(keyType, valueType):
				var countName = "__wire_count",
					indexName = "__wire_index",
					keyName = "__wire_key",
					resultName = "__wire_result",
					resultType = TMap(keyType, valueType);
				statements.push(TVar(countName, method(reader, "readMapHeader", [], TInt, request.span), request.span));
				statements.push(TVar(indexName, intLiteral(0, request.span), request.span));
				statements.push(TVar(resultName, new TypedExpression(TNewMap(keyType, valueType), resultType, request.span), request.span));
				statements.push(TVar(keyName, defaultValue(keyType, enums, request.span), request.span));
				statements.push(TWhile(new TypedExpression(TLess(local(indexName, TInt, request.span), local(countName, TInt, request.span)), TBool,
					request.span),
					decodeMapValueBody(session, classes, enums, resultName, resultType, keyType, valueType, reader, keyName, indexName, request.span),
					request.span));
				statements.push(TReturn(local(resultName, resultType, request.span), request.span));
			case TInstance(NominalKind.Enum, name, _):
				statements = decodeEnumValueStatements(session, classes, enums, name, type, reader, request.span);
			default:
				var methodName = primitiveReadMethod(type);
				if (methodName == null)
					throw 'No MessagePack decoder for "$type"';
				statements.push(TReturn(method(reader, methodName, [], type, request.span), request.span));
		}
		return generatedFunction(valueDecodeName(type), [{name: "reader", type: readerType}], type, statements, request);
	}

	static function decodeEnumValueStatements(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>, name:String,
			type:CompilerType, reader:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		var declaration = requiredEnum(enums, name, span),
			cases = wireEnumCases(declaration, span),
			countName = "__wire_enum_map_count",
			tagName = "__wire_enum_tag",
			payloadCountName = "__wire_enum_payload_count",
			result:Array<TypedStatement> = [
				TVar(countName, method(reader, "readMapHeader", [], TInt, span), span),
				TIf(new TypedExpression(TNot(new TypedExpression(TEqual(local(countName, TInt, span), intLiteral(1, span)), TBool, span)), TBool, span),
					[TThrow(stringLiteral('Invalid MessagePack shape for enum "$name"', span), span)], [], span),
				TVar(tagName, method(reader, "readInt", [], TInt, span), span),
				TVar(payloadCountName, method(reader, "readArrayHeader", [], TInt, span), span)
			],
			fallback:Array<TypedStatement> = [
				TThrow(stringLiteral('Unknown MessagePack constructor for enum "$name"', span), span)
			];
		for (caseIndex in 0...cases.length) {
			var wireCase = cases[cases.length - caseIndex - 1],
				branch:Array<TypedStatement> = [
					TIf(new TypedExpression(TNot(new TypedExpression(TEqual(local(payloadCountName, TInt, span),
						intLiteral(wireCase.caseDecl.params.length, span)), TBool, span)),
						TBool, span),
						[
							TThrow(stringLiteral('Invalid MessagePack payload for enum "$name.${wireCase.caseDecl.name}"', span), span)
						], [], span)
				];
			var arguments:Array<TypedExpression> = [];
			for (fieldIndex in 0...wireCase.caseDecl.params.length) {
				var parameterType = wireCase.caseDecl.params[fieldIndex],
					parameterName = enumParameterLocal(wireCase.index, fieldIndex),
					parameter = local(parameterName, parameterType, span);
				arguments.push(parameter);
				branch.push(TVar(parameterName, defaultValue(parameterType, enums, span), span));
				branch = branch.concat(decodeValueAssignment(session, classes, enums, parameter, parameterType, reader, span));
			}
			branch.push(TReturn(new TypedExpression(TEnumConstruct(name, wireCase.index, arguments), type, span), span));
			var condition = new TypedExpression(TEqual(local(tagName, TInt, span), intLiteral(wireCase.id, span)), TBool, span);
			fallback = [TIf(condition, branch, fallback, span)];
		}
		return result.concat(fallback);
	}

	static function encoder(type:CompilerType, request:WireCodecRequest):TypedFunction {
		var writerType = classType(WRITER),
			writerName = "__wire_writer",
			value = local("value", type, request.span),
			writer = local(writerName, writerType, request.span),
			statements:Array<TypedStatement> = [
				TVar(writerName, new TypedExpression(TNew(WRITER, [intLiteral(DEFAULT_MAX_BYTES, request.span)], true), writerType, request.span),
					request.span),
				TExpression(new TypedExpression(TCall(valueEncodeName(type), [writer, value]), TVoid, request.span), request.span),
				TReturn(method(writer, "getBytes", [], TBytes, request.span), request.span)
			];
		return generatedFunction(encodeName(type), [{name: "value", type: type}], TBytes, statements, request);
	}

	static function decoder(type:CompilerType, request:WireCodecRequest):TypedFunction {
		var readerType = classType(READER),
			readerName = "__wire_reader",
			bytes = local("bytes", TBytes, request.span),
			reader = local(readerName, readerType, request.span),
			statements:Array<TypedStatement> = [
				TVar(readerName, new TypedExpression(TNew(READER, [
					                                      bytes, intLiteral(DEFAULT_MAX_CONTAINER, request.span),
					intLiteral(DEFAULT_MAX_DEPTH, request.span),     intLiteral(DEFAULT_MAX_BYTES, request.span)
				],
					true), readerType,
					request.span), request.span),
				TReturn(new TypedExpression(TCall(valueDecodeName(type), [reader]), type, request.span), request.span)
			];
		return generatedFunction(decodeName(type), [{name: "bytes", type: TBytes}], type, statements, request);
	}

	static function decodeMapBody(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>, fields:Array<WireField>,
			reader:TypedExpression, keyName:String, span:SourceSpan):Array<TypedStatement> {
		var result:Array<TypedStatement> = [TVar(keyName, method(reader, "readInt", [], TInt, span), span)];
		var fallback:Array<TypedStatement> = [expressionStatement(method(reader, "skip", [], TVoid, span), span)];
		for (index in 0...fields.length) {
			var wireField = fields[fields.length - index - 1],
				field = wireField.field,
				fieldIndex = fields.length - index - 1,
				condition = new TypedExpression(TEqual(local(keyName, TInt, span), intLiteral(wireField.id, span)), TBool, span),
				assignment = decodeFieldAssignment(session, classes, enums, field, fieldIndex, reader, span);
			fallback = [TIf(condition, assignment, fallback, span)];
		}
		result = result.concat(fallback);
		result.push(TAssign("__wire_index", new TypedExpression(TAdd(local("__wire_index", TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	static function decodeArrayBody(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>, resultName:String,
			resultType:CompilerType, element:CompilerType, reader:TypedExpression, indexName:String, span:SourceSpan):Array<TypedStatement> {
		var target = new TypedExpression(TIndex(local(resultName, resultType, span), local(indexName, TInt, span)), element, span),
			result = decodeValueAssignment(session, classes, enums, target, element, reader, span);
		result.push(TAssign(indexName, new TypedExpression(TAdd(local(indexName, TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	static function decodeMapValueBody(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>, resultName:String,
			resultType:CompilerType, keyType:CompilerType, valueType:CompilerType, reader:TypedExpression, keyName:String, indexName:String,
			span:SourceSpan):Array<TypedStatement> {
		var key = local(keyName, keyType, span),
			map = local(resultName, resultType, span),
			target = new TypedExpression(TMapGet(map, key), valueType, span),
			result:Array<TypedStatement> = [
				TAssign(keyName, method(reader, mapKeyMethod(keyType, false), [], keyType, span), span)
			];
		result = result.concat(decodeValueAssignment(session, classes, enums, target, valueType, reader, span));
		result.push(TAssign(indexName, new TypedExpression(TAdd(local(indexName, TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	static function decodeFieldAssignment(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>, field:TypedField,
			fieldIndex:Int, reader:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		return decodeValueAssignment(session, classes, enums, local(fieldLocal(fieldIndex), field.type, span), field.type, reader, span);
	}

	static function decodeValueAssignment(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>, target:TypedExpression,
			type:CompilerType, reader:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		return switch type {
			case TNullable(element):
				var decoded = decodeValueExpression(session, classes, enums, reader, element, span),
					wrapped = new TypedExpression(TNullableWrap(decoded), type, span);
				[
					TIf(method(reader, "isNil", [], TBool, span), [
						expressionStatement(method(reader, "readNil", [], TVoid, span), span),
						assignValue(target, nullValue(type, span), span)
					], [assignValue(target, wrapped, span)], span)
				];
			default:
				[
					assignValue(target, decodeValueExpression(session, classes, enums, reader, type, span), span)
				];
		};
	}

	static function assignValue(target:TypedExpression, value:TypedExpression, span:SourceSpan):TypedStatement
		return switch target.expression {
			case TLocal(name): TAssign(name, value, span);
			case TIndex(array, index): TIndexAssign(array, index, value, span);
			case TMapGet(map, key): TMapAssign(map, key, value, span);
			default: throw "MessagePack decoder target must be a local, array index, or map entry";
		};

	static function decodeValueExpression(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>, reader:TypedExpression,
			type:CompilerType, span:SourceSpan):TypedExpression {
		return switch type {
			case TArray(_), TMap(_,
				_), TInstance(NominalKind.Class, _,
					_), TInstance(NominalKind.Enum, _, _): new TypedExpression(TCall(valueDecodeName(type), [reader]), type, span);
			default:
				var methodName = primitiveReadMethod(type);
				if (methodName == null)
					throw 'No MessagePack decoder for "$type"';
				method(reader, methodName, [], type, span);
		};
	}

	static function defaultValue(type:CompilerType, enums:Map<String, TypedEnum>, span:SourceSpan):TypedExpression
		return switch type {
			case TInt: intLiteral(0, span);
			case TFloat: new TypedExpression(TFloatLiteral(0.0), TFloat, span);
			case TBool: new TypedExpression(TBoolLiteral(false), TBool, span);
			case TString: stringLiteral("", span);
			case TBytes: new TypedExpression(TCall("haxe.io.Bytes.alloc", [intLiteral(0, span)]), TBytes, span);
			case TNullable(_): nullValue(type, span);
			case TArray(element): new TypedExpression(TNewArray(element, intLiteral(0, span)), type, span);
			case TMap(key, value): new TypedExpression(TNewMap(key, value), type, span);
			case TInstance(NominalKind.Class, name, _): new TypedExpression(TNew(name, [], false), type, span);
			case TInstance(NominalKind.Enum, name, _):
				var cases = wireEnumCases(requiredEnum(enums, name, span), span);
				if (cases.length == 0)
					BodyTyper.fail("E1024", 'MessagePack enum "$name" must declare at least one constructor', span);
				var first = cases[0];
				new TypedExpression(TEnumConstruct(name, first.index, [for (parameter in first.caseDecl.params) defaultValue(parameter, enums, span)]), type,
					span);
			default: throw 'No MessagePack default for "$type"';
		};

	static function isNullValue(value:TypedExpression, type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TEqual(value, nullValue(type, span)), TBool, span);

	static function nullValue(type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span);

	static function primitiveMethod(type:CompilerType):Null<String>
		return switch type {
			case TInt: "writeInt";
			case TFloat: "writeFloat";
			case TBool: "writeBool";
			case TString: "writeString";
			case TBytes: "writeBinary";
			default: null;
		};

	static function primitiveReadMethod(type:CompilerType):Null<String>
		return switch type {
			case TInt: "readInt";
			case TFloat: "readFloat";
			case TBool: "readBool";
			case TString: "readString";
			case TBytes: "readBinary";
			default: null;
		};

	static function mapKeyMethod(type:CompilerType, writing:Bool):String {
		var methodName = writing ? primitiveMethod(type) : primitiveReadMethod(type);
		if (methodName == null)
			throw 'No MessagePack map key method for "$type"';
		return methodName;
	}

	static function typeKey(type:CompilerType):String
		return switch type {
			case TInt: "int";
			case TFloat: "float";
			case TBool: "bool";
			case TString: "string";
			case TBytes: "bytes";
			case TNullable(element): "nullable_" + typeKey(element);
			case TArray(element): "array_" + typeKey(element);
			case TMap(key, value):
				(switch key {
					case TString: "map_string_";
					case TInt: "map_int_";
					default: throw 'No MessagePack map key for "$key"';
				}) + typeKey(value);
			case TInstance(NominalKind.Class, name, _): "class_" + StringTools.replace(name, ".", "_");
			case TInstance(NominalKind.Enum, name, _): "enum_" + StringTools.replace(name, ".", "_");
			default: throw 'No MessagePack codec key for "$type"';
		};

	static function isWireClass(session:TypingSession, name:String):Bool {
		var declaration = session.classDecls.get(name);
		if (declaration == null)
			return false;
		for (metadata in declaration.metadata)
			if (metadata.name == "wire") {
				if (metadata.arguments.length != 0)
					BodyTyper.fail("E1024", '@:wire does not accept arguments', metadata.span);
				return true;
			}
		return false;
	}

	static function isWireEnum(session:TypingSession, name:String):Bool {
		var declaration = session.enumDecls.get(name);
		if (declaration == null)
			return false;
		for (metadata in declaration.metadata)
			if (metadata.name == "wire") {
				if (metadata.arguments.length != 0)
					BodyTyper.fail("E1024", '@:wire does not accept arguments', metadata.span);
				return true;
			}
		return false;
	}

	static function requiredClass(classes:Map<String, TypedClass>, name:String, span:SourceSpan):TypedClass {
		var declaration = classes.get(name);
		if (declaration == null)
			BodyTyper.fail("E1024", 'MessagePack record "$name" is not available in the typed program', span);
		return cast declaration;
	}

	static function requiredEnum(enums:Map<String, TypedEnum>, name:String, span:SourceSpan):TypedEnum {
		var declaration = enums.get(name);
		if (declaration == null)
			BodyTyper.fail("E1024", 'MessagePack enum "$name" is not available in the typed program', span);
		return cast declaration;
	}

	static function hasDirectStorage(field:TypedField):Bool
		return switch [field.readAccess, field.writeAccess] {
			case [GetAccess, _], [_, SetAccess], [NeverAccess, _], [_, NeverAccess]: false;
			default: true;
		};

	static function classType(name:String):CompilerType
		return TInstance(NominalKind.Class, name, []);

	static function local(name:String, type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TLocal(name), type, span);

	static function intLiteral(value:Int, span:SourceSpan):TypedExpression
		return new TypedExpression(TIntLiteral(value), TInt, span);

	static function stringLiteral(value:String, span:SourceSpan):TypedExpression
		return new TypedExpression(TStringLiteral(value), TString, span);

	static function method(receiver:TypedExpression, name:String, arguments:Array<TypedExpression>, result:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TMethodCall(receiver, receiverTypeName(receiver.type) + "." + name, arguments), result, span);

	static function receiverTypeName(type:CompilerType):String
		return switch type {
			case TInstance(_, name, _): name;
			default: throw 'MessagePack method receiver must be a nominal class, got "$type"';
		};

	static function expressionStatement(expression:TypedExpression, span:SourceSpan):TypedStatement
		return TExpression(expression, span);

	static function fieldLocal(index:Int):String
		return "__wire_field_" + index;

	static function enumParameterLocal(constructor:Int, field:Int):String
		return '__wire_enum_${constructor}_$field';

	static function generatedFunction(name:String, arguments:Array<{name:String, type:CompilerType}>, result:CompilerType, statements:Array<TypedStatement>,
			request:WireCodecRequest):TypedFunction
		return {
			name: name,
			genericOrigin: request.origin,
			typeArguments: null,
			owner: null,
			isStatic: true,
			isConstructor: false,
			arguments: arguments,
			result: result,
			statements: statements,
			cells: [],
			cellCaptures: [],
			span: request.span
		};
}
