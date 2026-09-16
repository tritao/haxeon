package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedClass;
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

/** Emits the first compiler-owned MessagePack codec profile. */
class WireCodecGenerator {
	static inline final ENCODE_PREFIX:String = "$wire:encode:";
	static inline final DECODE_PREFIX:String = "$wire:decode:";
	static inline final VALUE_ENCODE_PREFIX:String = "$wire:value-encode:";
	static inline final VALUE_DECODE_PREFIX:String = "$wire:value-decode:";
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
	public static function generate(session:TypingSession, classes:Array<TypedClass>):Array<TypedFunction> {
		var classesByName:Map<String, TypedClass> = [];
		for (classDecl in classes)
			classesByName.set(classDecl.name, classDecl);
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
			collectType(session, request.type, classesByName, reachable, visiting, path, request.span);
		}
		var keys = [for (key in reachable.keys()) key];
		keys.sort(Reflect.compare);
		var result:Array<TypedFunction> = [];
		for (key in keys) {
			var type = reachable.get(key), request = requests.get(key);
			if (request == null)
				request = {type: type, origin: roots[0].origin, span: roots[0].span};
			result.push(valueEncoder(session, type, classesByName, request));
			result.push(valueDecoder(session, type, classesByName, request));
			if (rootKeys.exists(key)) {
				result.push(encoder(type, request));
				result.push(decoder(type, request));
			}
		}
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
			case TInstance(NominalKind.Class, name, arguments): arguments.length == 0 && isWireClass(session, name);
			default: false;
		};

	static function collectType(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>, reachable:Map<String, CompilerType>,
			visiting:Map<String, Bool>, path:Array<String>, span:SourceSpan):Void {
		if (!isRequestType(session, type))
			BodyTyper.fail("E1024", 'MessagePack does not support type "$type" in the current wire profile', span);
		var key = typeKey(type);
		if (reachable.exists(key))
			return;
		if (visiting.exists(key))
			BodyTyper.fail("E1024", 'MessagePack record schema cannot be recursive (${path.concat([key]).join(" -> ")})', span);
		visiting.set(key, true);
		path.push(key);
		switch type {
			case TNullable(element):
				collectType(session, element, classes, reachable, visiting, path, span);
			case TArray(element):
				collectType(session, element, classes, reachable, visiting, path, span);
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
					collectType(session, wireField.field.type, classes, reachable, visiting, path, wireField.field.span);
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

	static function valueEncoder(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>, request:WireCodecRequest):TypedFunction {
		var writerType = classType(WRITER),
			valueType = type,
			writer = local("writer", writerType, request.span),
			value = local("value", valueType, request.span),
			statements = encodeValueStatements(session, classes, writer, value, type, request.span);
		return generatedFunction(valueEncodeName(type), [{name: "writer", type: writerType}, {name: "value", type: valueType}], TVoid, statements, request);
	}

	static function encodeValueStatements(session:TypingSession, classes:Map<String, TypedClass>, writer:TypedExpression, value:TypedExpression,
			type:CompilerType, span:SourceSpan):Array<TypedStatement> {
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

	static function valueDecoder(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>, request:WireCodecRequest):TypedFunction {
		var readerType = classType(READER),
			reader = local("reader", readerType, request.span),
			statements:Array<TypedStatement> = [];
		switch type {
			case TNullable(element):
				var decoded = decodeValueExpression(session, classes, reader, element, request.span),
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
					statements.push(TVar(fieldLocal(index), defaultValue(fields[index].field.type, request.span), request.span));
				statements.push(TWhile(new TypedExpression(TLess(local(indexName, TInt, request.span), local(countName, TInt, request.span)), TBool,
					request.span),
					decodeMapBody(session, classes, fields, reader, keyName, request.span), request.span));
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
					decodeArrayBody(session, classes, resultName, resultType, element, reader, indexName, request.span), request.span));
				statements.push(TReturn(local(resultName, resultType, request.span), request.span));
			default:
				var methodName = primitiveReadMethod(type);
				if (methodName == null)
					throw 'No MessagePack decoder for "$type"';
				statements.push(TReturn(method(reader, methodName, [], type, request.span), request.span));
		}
		return generatedFunction(valueDecodeName(type), [{name: "reader", type: readerType}], type, statements, request);
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

	static function decodeMapBody(session:TypingSession, classes:Map<String, TypedClass>, fields:Array<WireField>, reader:TypedExpression, keyName:String,
			span:SourceSpan):Array<TypedStatement> {
		var result:Array<TypedStatement> = [TVar(keyName, method(reader, "readInt", [], TInt, span), span)];
		var fallback:Array<TypedStatement> = [expressionStatement(method(reader, "skip", [], TVoid, span), span)];
		for (index in 0...fields.length) {
			var wireField = fields[fields.length - index - 1],
				field = wireField.field,
				fieldIndex = fields.length - index - 1,
				condition = new TypedExpression(TEqual(local(keyName, TInt, span), intLiteral(wireField.id, span)), TBool, span),
				assignment = decodeFieldAssignment(session, classes, field, fieldIndex, reader, span);
			fallback = [TIf(condition, assignment, fallback, span)];
		}
		result = result.concat(fallback);
		result.push(TAssign("__wire_index", new TypedExpression(TAdd(local("__wire_index", TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	static function decodeArrayBody(session:TypingSession, classes:Map<String, TypedClass>, resultName:String, resultType:CompilerType, element:CompilerType,
			reader:TypedExpression, indexName:String, span:SourceSpan):Array<TypedStatement> {
		var target = new TypedExpression(TIndex(local(resultName, resultType, span), local(indexName, TInt, span)), element, span),
			result = decodeValueAssignment(session, classes, target, element, reader, span);
		result.push(TAssign(indexName, new TypedExpression(TAdd(local(indexName, TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	static function decodeFieldAssignment(session:TypingSession, classes:Map<String, TypedClass>, field:TypedField, fieldIndex:Int, reader:TypedExpression,
			span:SourceSpan):Array<TypedStatement> {
		return decodeValueAssignment(session, classes, local(fieldLocal(fieldIndex), field.type, span), field.type, reader, span);
	}

	static function decodeValueAssignment(session:TypingSession, classes:Map<String, TypedClass>, target:TypedExpression, type:CompilerType,
			reader:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		return switch type {
			case TNullable(element):
				var decoded = decodeValueExpression(session, classes, reader, element, span),
					wrapped = new TypedExpression(TNullableWrap(decoded), type, span);
				[
					TIf(method(reader, "isNil", [], TBool, span), [
						expressionStatement(method(reader, "readNil", [], TVoid, span), span),
						assignValue(target, nullValue(type, span), span)
					], [assignValue(target, wrapped, span)], span)
				];
			default:
				[
					assignValue(target, decodeValueExpression(session, classes, reader, type, span), span)
				];
		};
	}

	static function assignValue(target:TypedExpression, value:TypedExpression, span:SourceSpan):TypedStatement
		return switch target.expression {
			case TLocal(name): TAssign(name, value, span);
			case TIndex(array, index): TIndexAssign(array, index, value, span);
			default: throw "MessagePack decoder target must be a local or array index";
		};

	static function decodeValueExpression(session:TypingSession, classes:Map<String, TypedClass>, reader:TypedExpression, type:CompilerType,
			span:SourceSpan):TypedExpression {
		return switch type {
			case TArray(_), TInstance(NominalKind.Class, _, _): new TypedExpression(TCall(valueDecodeName(type), [reader]), type, span);
			default:
				var methodName = primitiveReadMethod(type);
				if (methodName == null)
					throw 'No MessagePack decoder for "$type"';
				method(reader, methodName, [], type, span);
		};
	}

	static function defaultValue(type:CompilerType, span:SourceSpan):TypedExpression
		return switch type {
			case TInt: intLiteral(0, span);
			case TFloat: new TypedExpression(TFloatLiteral(0.0), TFloat, span);
			case TBool: new TypedExpression(TBoolLiteral(false), TBool, span);
			case TString: stringLiteral("", span);
			case TBytes: new TypedExpression(TCall("haxe.io.Bytes.alloc", [intLiteral(0, span)]), TBytes, span);
			case TNullable(_): nullValue(type, span);
			case TArray(element): new TypedExpression(TNewArray(element, intLiteral(0, span)), type, span);
			case TInstance(NominalKind.Class, name, _): new TypedExpression(TNew(name, [], false), type, span);
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

	static function typeKey(type:CompilerType):String
		return switch type {
			case TInt: "int";
			case TFloat: "float";
			case TBool: "bool";
			case TString: "string";
			case TBytes: "bytes";
			case TNullable(element): "nullable_" + typeKey(element);
			case TArray(element): "array_" + typeKey(element);
			case TInstance(NominalKind.Class, name, _): "class_" + StringTools.replace(name, ".", "_");
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

	static function requiredClass(classes:Map<String, TypedClass>, name:String, span:SourceSpan):TypedClass {
		var declaration = classes.get(name);
		if (declaration == null)
			BodyTyper.fail("E1024", 'MessagePack record "$name" is not available in the typed program', span);
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
