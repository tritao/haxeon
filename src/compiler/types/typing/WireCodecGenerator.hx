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
		var keys = [for (key in session.wireCodecRequests.keys()) key];
		keys.sort(Reflect.compare);
		var result:Array<TypedFunction> = [];
		for (key in keys) {
			var request:WireCodecRequest = cast session.wireCodecRequests.get(key);
			if (request == null)
				continue;
			var type = request.type;
			validateType(session, type, classesByName, request.span);
			result.push(valueEncoder(type, classesByName, request));
			result.push(valueDecoder(type, classesByName, request));
			result.push(encoder(type, request));
			result.push(decoder(type, request));
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
			case TInstance(NominalKind.Class, name, arguments): arguments.length == 0 && isWireClass(session, name);
			default: false;
		};

	static function validateType(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>, span:SourceSpan):Void {
		if (!isRequestType(session, type))
			BodyTyper.fail("E1024", 'MessagePack does not support type "$type" in the current wire profile', span);
		switch type {
			case TInstance(NominalKind.Class, name, _):
				var declaration = classes.get(name);
				if (declaration == null)
					BodyTyper.fail("E1024", 'MessagePack record "$name" is not available in the typed program', span);
				if (declaration.base != null)
					BodyTyper.fail("E1024", 'MessagePack record "$name" cannot extend another class yet', declaration.span);
				var fields = serializableFields(declaration, span);
				if (fields.length == 0)
					BodyTyper.fail("E1024", 'MessagePack record "$name" must declare at least one instance field', declaration.span);
			default:
		}
	}

	static function serializableFields(declaration:TypedClass, span:SourceSpan):Array<TypedField> {
		var result:Array<TypedField> = [];
		for (field in declaration.fields) {
			if (field.isStatic)
				continue;
			if (field.initializer != null)
				BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" cannot have an initializer yet', field.span);
			if (field.isFinal)
				BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" cannot be final yet', field.span);
			if (!hasDirectStorage(field))
				BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" must have direct storage', field.span);
			if (primitiveMethod(field.type) == null)
				BodyTyper.fail("E1024", 'MessagePack record field "${declaration.name}.${field.name}" has unsupported type "${field.type}"', field.span);
			result.push(field);
		}
		return result;
	}

	static function valueEncoder(type:CompilerType, classes:Map<String, TypedClass>, request:WireCodecRequest):TypedFunction {
		var writerType = classType(WRITER),
			valueType = type,
			statements:Array<TypedStatement> = [];
		switch type {
			case TInstance(NominalKind.Class, name, _):
				var declaration = requiredClass(classes, name, request.span),
					fields = serializableFields(declaration, request.span),
					writer = local("writer", writerType, request.span),
					value = local("value", valueType, request.span);
				statements.push(expressionStatement(method(writer, "writeMapHeader", [intLiteral(fields.length, request.span)], TVoid, request.span),
					request.span));
				for (field in fields) {
					statements.push(expressionStatement(method(writer, "writeString", [stringLiteral(field.name, request.span)], TVoid, request.span),
						request.span));
					statements.push(expressionStatement(method(writer, cast primitiveMethod(field.type),
						[new TypedExpression(TField(value, field.name), field.type, field.span)], TVoid, request.span),
						request.span));
				}
			default:
				var methodName = cast primitiveMethod(type);
				statements.push(expressionStatement(method(local("writer", writerType, request.span), methodName, [local("value", valueType, request.span)],
					TVoid, request.span),
					request.span));
		}
		return generatedFunction(valueEncodeName(type), [{name: "writer", type: writerType}, {name: "value", type: valueType}], TVoid, statements, request);
	}

	static function valueDecoder(type:CompilerType, classes:Map<String, TypedClass>, request:WireCodecRequest):TypedFunction {
		var readerType = classType(READER),
			statements:Array<TypedStatement> = [];
		switch type {
			case TInstance(NominalKind.Class, name, _):
				var declaration = requiredClass(classes, name, request.span),
					fields = serializableFields(declaration, request.span),
					reader = local("reader", readerType, request.span),
					countName = "__wire_count",
					indexName = "__wire_index",
					keyName = "__wire_key",
					resultName = "__wire_result";
				statements.push(TVar(countName, method(reader, "readMapHeader", [], TInt, request.span), request.span));
				statements.push(TVar(indexName, intLiteral(0, request.span), request.span));
				for (index in 0...fields.length)
					statements.push(TVar(fieldLocal(index), defaultValue(fields[index].type, request.span), request.span));
				statements.push(TWhile(new TypedExpression(TLess(local(indexName, TInt, request.span), local(countName, TInt, request.span)), TBool,
					request.span),
					decodeMapBody(fields, reader, keyName, request.span), request.span));
				var resultType = type,
					newValue = new TypedExpression(TNew(name, [], false), resultType, request.span);
				statements.push(TVar(resultName, newValue, request.span));
				for (index in 0...fields.length)
					statements.push(TFieldAssign(local(resultName, resultType, request.span), fields[index].name,
						local(fieldLocal(index), fields[index].type, request.span), request.span));
				statements.push(TReturn(local(resultName, resultType, request.span), request.span));
			default:
				statements.push(TReturn(method(local("reader", readerType, request.span), cast primitiveReadMethod(type), [], type, request.span),
					request.span));
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

	static function decodeMapBody(fields:Array<TypedField>, reader:TypedExpression, keyName:String, span:SourceSpan):Array<TypedStatement> {
		var result:Array<TypedStatement> = [TVar(keyName, method(reader, "readString", [], TString, span), span)];
		var fallback:Array<TypedStatement> = [expressionStatement(method(reader, "skip", [], TVoid, span), span)];
		for (index in 0...fields.length) {
			var field = fields[fields.length - index - 1],
				fieldIndex = fields.length - index - 1,
				condition = new TypedExpression(TEqual(local(keyName, TString, span), stringLiteral(field.name, span)), TBool, span),
				assignment = TAssign(fieldLocal(fieldIndex), method(reader, cast primitiveReadMethod(field.type), [], field.type, span), span);
			fallback = [TIf(condition, [assignment], fallback, span)];
		}
		result = result.concat(fallback);
		result.push(TAssign("__wire_index", new TypedExpression(TAdd(local("__wire_index", TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	static function defaultValue(type:CompilerType, span:SourceSpan):TypedExpression
		return switch type {
			case TInt: intLiteral(0, span);
			case TFloat: new TypedExpression(TFloatLiteral(0.0), TFloat, span);
			case TBool: new TypedExpression(TBoolLiteral(false), TBool, span);
			case TString: stringLiteral("", span);
			case TBytes: new TypedExpression(TCall("haxe.io.Bytes.alloc", [intLiteral(0, span)]), TBytes, span);
			default: throw 'No MessagePack default for "$type"';
		};

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
