package compiler.types.typing;

import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.types.typing.HelperRequests.HelperRequest;
import compiler.types.TypedAst.TypedFunctionRole;
import compiler.core.Source.SourceFile;
import compiler.core.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedEnum;
import compiler.types.TypedAst.TypedEnumCase;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedField;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.core.Provides;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypeRelations;
import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstTypeAlias;
import compiler.syntax.Ast.AstMetadata;
import compiler.types.typing.HelperRequests.WireCodecRequest;


private typedef WireField = {
	final field:TypedField;
	// Zero denotes a name key. Numeric IDs only come from metadata.
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
	static inline final STRING_COMPARE_NAME:String = "$wire:map-string-compare";
	static inline final ENUM_COMPARE_PREFIX:String = "$wire:map-enum-compare:";
	static inline final WRITER:String = "haxeon.wire.MessagePackWriter";
	static inline final READER:String = "haxeon.wire.MessagePackReader";
	static inline final JSON_WRITER:String = "haxeon.wire.JsonWireWriter";
	static inline final JSON_READER:String = "haxeon.wire.JsonWireReader";
	/** Whether this generation makes the JSON codecs (`generateJson`) rather than the binary ones (`generate`). */
	final jsonMode:Bool;

	function new(jsonMode:Bool)
		this.jsonMode = jsonMode;

	inline function writerClassName():String
		return jsonMode ? JSON_WRITER : WRITER;

	inline function readerClassName():String
		return jsonMode ? JSON_READER : READER;

	static inline final DEFAULT_MAX_BYTES:Int = 16 * 1024 * 1024;
	static inline final DEFAULT_MAX_CONTAINER:Int = 1000000;
	static inline final DEFAULT_MAX_DEPTH:Int = 64;

	/**
	 * Register one source-level encode/decode request for later code generation, and return the type it is keyed by (see
	 * `ValueEqualityGenerator.request`): name the codec from that type.
	 */
	public static function request(session:TypingSession, type:CompilerType, origin:String,
			span:SourceSpan):CompilerType {
		type = session.monomorphs.closeReached(type);
		if (!isRequestType(session, type))
			BodyTyper.fail("E1024", 'MessagePack does not support type "$type" in the current wire profile', span);
		var key = typeKey(type);
		session.output.requests.add(WireCodecHelper(key, {type: type, origin: origin, span: span}));
		return type;
	}

	public static function requestJson(session:TypingSession, type:CompilerType, origin:String,
			span:SourceSpan):CompilerType {
		type = session.monomorphs.closeReached(type);
		if (!isRequestType(session, type))
			BodyTyper.fail("E1024", 'JSON does not support type "$type" in the current wire profile', span);
		var key = typeKey(type);
		session.output.requests.add(JsonCodecHelper(key, {type: type, origin: origin, span: span}));
		return type;
	}

	/** Generate wrappers and value codecs requested while typing source bodies. */
	public static function generate(session:TypingSession, classes:Array<TypedClass>,
			enums:Array<TypedEnum>):Array<TypedFunction>
		return new WireCodecGenerator(false).generateRequested(session, classes, enums,
			session.programOutput.requests.wireCodecs);

	public static function generateJson(session:TypingSession, classes:Array<TypedClass>,
			enums:Array<TypedEnum>):Array<TypedFunction>
		return new WireCodecGenerator(true).generateRequested(session, classes, enums,
			session.programOutput.requests.jsonCodecs);

	function generateRequested(session:TypingSession, classes:Array<TypedClass>, enums:Array<TypedEnum>,
			requested:Map<String, WireCodecRequest>):Array<TypedFunction> {
		var classesByName:Map<String, TypedClass> = [];
		for (classDecl in classes)
			classesByName.set(classDecl.name, classDecl);
		var enumsByName:Map<String, TypedEnum> = [];
		for (enumDecl in enums)
			enumsByName.set(enumDecl.name, enumDecl);
		var roots:Array<WireCodecRequest> = [
			for (key in requested.keys())
				cast requested.get(key)
		];
		if (roots.length == 0)
			return [];
		roots.sort(function(left, right) return Reflect.compare(typeKey(left.type), typeKey(right.type)));
		var reachable:Map<String, WireCodecRequest> = [],
			visiting:Map<String, Bool> = [],
			path:Array<String> = [];
		for (request in roots)
			collectType(session, request.type, classesByName, enumsByName, reachable, visiting, path,
				request.origin, request.span);
		var keys = [for (key in reachable.keys()) key];
		keys.sort(Reflect.compare);
		var result:Array<TypedFunction> = [];
		var needsIntComparator = false,
			needsStringComparator = false,
			enumComparatorTypes:Map<String, CompilerType> = [];
		for (key in keys) {
			var reached = reachable.get(key), root = requested.get(key), type = reached.type;
			// Use a caller that reaches this codec so unrelated edits cannot retire it.
			// A type's span keeps the generated function independent of which caller was typed first.
			var request:WireCodecRequest = {
				type: type,
				origin: root == null ? reached.origin : root.origin,
				span: canonicalSpan(session, type, classesByName, enumsByName)
			};
			if (switch type {
				case TMap(TInt, _): true;
				default: false;
			})
				needsIntComparator = true;
			if (switch type {
				case TMap(TString, _): true;
				default: false;
			})
				needsStringComparator = true;
			switch type {
				case TMap(TInstance(NominalKind.Enum, _, _), _):
					var mapKey = switch type {
						case TMap(keyType, _): keyType;
						default: throw new InternalError("Enum comparator requires an enum map key");
					};
					enumComparatorTypes.set(typeKey(mapKey), mapKey);
				default:
			}
			result.push(valueEncoder(session, type, classesByName, enumsByName, request));
			result.push(valueDecoder(session, type, classesByName, enumsByName, request));
			if (root != null) {
				result.push(encoder(type, request));
				result.push(decoder(type, request));
			}
		}
		// The comparators are shared by every codec, so nothing in which codecs a run happened to request may reach them.
		var shared:WireCodecRequest = {
			type: roots[0].type,
			origin: roots[0].origin,
			span: canonicalSpan(session, TInt, classesByName, enumsByName)
		};
		if (needsIntComparator)
			result.push(intComparator(shared));
		if (needsStringComparator)
			result.push(stringComparator(shared));
		var enumComparatorKeys = [for (key in enumComparatorTypes.keys()) key];
		enumComparatorKeys.sort(Reflect.compare);
		for (key in enumComparatorKeys) {
			var enumType = enumComparatorTypes.get(key),
				enumName = switch enumType {
					case TInstance(NominalKind.Enum, name, _): name;
					default: throw new InternalError("Enum comparator requires an enum map key");
				};
			result.push(enumComparator(enumType, requiredEnum(enumsByName, enumName, shared.span), shared));
		}
		return result;
	}

	/** The span of a codec for a type with no declaration of its own. */
	static final syntheticSpan = new SourceSpan(new SourceFile("<generated>", ""), 0, 0);

	/** The span of what the codec is for: a wire typedef, class or enum declaration, or a fixed one for types without. */
	function canonicalSpan(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>,
			enums:Map<String, TypedEnum>):SourceSpan {
		var declared:Null<SourceSpan> = declarationSpan(session, type, classes, enums);
		if (declared != null)
			return declared;
		return syntheticSpan;
	}

	function declarationSpan(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>,
			enums:Map<String, TypedEnum>):Null<SourceSpan>
		return switch type {
			case TAnonymous(_, _):
				var alias = wireAlias(session, type);
				alias == null ? null : alias.span;
			case TInstance(NominalKind.Class, name, _):
				classes.exists(name) ? classes.get(name).span : null;
			case TInstance(NominalKind.Enum, name, _):
				enums.exists(name) ? enums.get(name).span : null;
			case TNullable(element), TArray(element):
				declarationSpan(session, element, classes, enums);
			case TMap(key, value):
				var inValue = declarationSpan(session, value, classes, enums);
				inValue != null ? inValue : declarationSpan(session, key, classes, enums);
			case TAbstract(_, _, representation):
				declarationSpan(session, representation, classes, enums);
			default: null;
		};

	public static function encodeName(type:CompilerType):String
		return ENCODE_PREFIX + typeKey(type);

	public static function decodeName(type:CompilerType):String
		return DECODE_PREFIX + typeKey(type);

	public static function jsonEncodeName(type:CompilerType):String
		return "$json:encode:" + typeKey(type);

	public static function jsonDecodeName(type:CompilerType):String
		return "$json:decode:" + typeKey(type);

	function rootEncodeName(type:CompilerType):String
		return jsonMode ? jsonEncodeName(type) : encodeName(type);

	function rootDecodeName(type:CompilerType):String
		return jsonMode ? jsonDecodeName(type) : decodeName(type);

	function valueEncodeName(type:CompilerType):String
		return (jsonMode ? "$json:value-encode:" : VALUE_ENCODE_PREFIX) + typeKey(type);

	function valueDecodeName(type:CompilerType):String
		return (jsonMode ? "$json:value-decode:" : VALUE_DECODE_PREFIX) + typeKey(type);

	static function isRequestType(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TInt, TInt64, TFloat, TBool, TString, TBytes: true;
			case TNullable(element): isRequestType(session, element);
			case TArray(element): isRequestType(session, element) && RuntimeType.arrayName(element) != null;
			case TMap(key, value): isMapKeyType(session, key) && isRequestType(session, value)
				&& RuntimeType.mapName(key, value) != null;
			case TAbstract(_, _, representation): isRequestType(session, representation);
			case TAnonymous(_, _): true;
			case TInstance(NominalKind.Class, name, arguments): arguments.length == 0
				&& session.classDecls.exists(name);
			case TInstance(NominalKind.Enum, name, arguments): arguments.length == 0 && session.enumDecls.exists(name);
			default: false;
		};

	static function isMapKeyType(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TString, TInt: true;
			case TInstance(NominalKind.Enum, name, arguments): arguments.length == 0
				&& isNullaryWireEnum(session, name);
			default: false;
		};

	static function wireAlias(session:TypingSession, type:CompilerType):Null<AstTypeAlias> {
		var fields = switch type {
			case TAnonymous(_, fields): fields;
			default: throw new InternalError("Expected a structural wire type");
		};
		var explicit:Null<AstTypeAlias> = null, inferred:Null<AstTypeAlias> = null;
		for (alias in session.declarations.aliasesInOrder()) {
			if (alias.typeParameters.length != 0)
				continue;
			var source = switch alias.type {
				case AnonymousType(fields): fields;
				default: continue;
			};
			if (source.length != fields.length
				|| !Lambda.foreach(source, member -> Lambda.exists(fields, field -> field.name == member.name)))
				continue;
			var annotated = Lambda.exists(alias.metadata, meta -> meta.name == "wire")
				|| Lambda.exists(source, field -> Lambda.exists(field.metadata, meta -> meta.name == "id"));
			if (!annotated && inferred != null)
				continue;
			var resolved:CompilerType;
			try {
				resolved = session.declarations.resolve(AstType.NamedType(alias.name), alias.span);
			} catch (error:CompileError) {
				// An unused typedef with the same field names may have an unresolved type.
				if (annotated)
					throw error;
				continue;
			}
			if (!TypeRelations.equals(resolved, type))
				continue;
			if (annotated) {
				validateWireMarker(alias.metadata);
				if (explicit != null)
					BodyTyper.fail("E1024",
						'Wire typedefs "${explicit.name}" and "${alias.name}" have the same structural type',
						alias.span);
				explicit = alias;
			} else
				inferred = alias;
		}
		return explicit ?? inferred;
	}

	function anonymousWireFields(session:TypingSession, type:CompilerType, span:SourceSpan):Array<WireField> {
		var alias = wireAlias(session, type);
		var sourceFields = alias == null ? [] : switch alias.type {
			case AnonymousType(fields): fields;
			default: throw new InternalError("Wire alias must be anonymous");
		};
		var resolvedFields = switch type {
			case TAnonymous(_, fields): fields;
			default: throw new InternalError("Wire type must be anonymous");
		};
		var owner = alias == null ? "record" : alias.name;
		var result:Array<WireField> = [], ids:Map<Int, String> = [];
		var resolvedByName = [for (field in resolvedFields) field.name => field];
		var names = alias == null
			? [for (field in resolvedFields) field.name] : [for (field in sourceFields) field.name];
		for (index in 0...names.length) {
			var resolved = resolvedByName.get(names[index]),
				metadata:Array<AstMetadata> = alias == null ? [] : sourceFields[index].metadata,
				position = alias == null ? span : sourceFields[index].span;
			if (resolved == null)
				throw new InternalError('Missing resolved field "${names[index]}" in wire record "$owner"');
			var field:TypedField = {
				name: resolved.name,
				metadata: metadata,
				type: resolved.type,
				initializer: null,
				inlineValue: null,
				readAccess: null,
				writeAccess: null,
				isStatic: false,
				isInline: false,
				isFinal: resolved.isFinal,
				span: position
			};
			var id = memberId(metadata, owner + "." + field.name, position);
			if (id != 0 && ids.exists(id))
				BodyTyper.fail("E1024", 'Duplicate @:id($id) in $owner', position);
			ids.set(id, field.name);
			if (!isRequestType(session, field.type))
				BodyTyper.fail("E1024", 'Wire record field "$owner.${field.name}" has unsupported type "${field.type}"',
					position);
			result.push({field: field, id: id});
		}
		return orderFields(result, owner);
	}

	function orderFields(fields:Array<WireField>, owner:String):Array<WireField> {
		if (fields.length > 0) {
			var named = !Lambda.exists(fields, member -> member.id != 0);
			for (member in fields)
				checkKeyMode(named, member.id, owner + "." + member.field.name, member.field.span);
			if (!named)
				fields.sort((left, right) -> Reflect.compare(left.id, right.id));
			else if (!jsonMode)
				fields.sort((left, right) -> Reflect.compare(left.field.name, right.field.name));
		}
		return fields;
	}

	function checkKeyMode(named:Bool, id:Int, member:String, span:SourceSpan):Void {
		if (!named && id == 0)
			BodyTyper.fail("E1024", 'Wire member "$member" needs @:id(n): cannot mix named and numbered members', span);
	}

	function collectType(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>,
			enums:Map<String, TypedEnum>,
			reachable:Map<String, WireCodecRequest>, visiting:Map<String, Bool>, path:Array<String>, origin:String,
			span:SourceSpan):Void {
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
			BodyTyper.fail("E1024",
				'MessagePack $schemaKind schema cannot be recursive (${path.concat([key]).join(" -> ")})', span);
		}
		visiting.set(key, true);
		path.push(key);
		switch type {
			case TAbstract(_, _, representation):
				collectType(session, representation, classes, enums, reachable, visiting, path, origin, span);
			case TAnonymous(_, _):
				for (wireField in anonymousWireFields(session, type, span))
					collectType(session, wireField.field.type, classes, enums, reachable, visiting, path, origin,
						wireField.field.span);
			case TNullable(element):
				collectType(session, element, classes, enums, reachable, visiting, path, origin, span);
			case TArray(element):
				collectType(session, element, classes, enums, reachable, visiting, path, origin, span);
			case TMap(key, value):
				switch key {
					case TInstance(NominalKind.Enum, _, _):
						collectType(session, key, classes, enums, reachable, visiting, path, origin, span);
					default:
				}
				collectType(session, value, classes, enums, reachable, visiting, path, origin, span);
			case TInstance(NominalKind.Class, name, _):
				var declaration = classes.get(name);
				if (declaration == null)
					BodyTyper.fail("E1024", 'MessagePack record "$name" is not available in the typed program', span);
				if (declaration.base != null)
					BodyTyper.fail("E1024", 'MessagePack record "$name" cannot extend another class yet',
						declaration.span);
				validateWireMarker(session.classDecls.get(name).metadata);
				if (declaration.isNativeValue)
					BodyTyper.fail("E1024", 'Wire record "$name" requires managed storage', span);
				var fields = serializableFields(session, declaration);
				if (fields.length == 0)
					BodyTyper.fail("E1024", 'MessagePack record "$name" must declare at least one instance field',
						declaration.span);
				for (wireField in fields)
					collectType(session, wireField.field.type, classes, enums, reachable, visiting, path, origin,
						wireField.field.span);
			case TInstance(NominalKind.Enum, name, _):
				validateWireMarker(session.enumDecls.get(name).metadata);
				var declaration = requiredEnum(enums, name, span),
					cases = wireEnumCases(declaration, span);
				if (cases.length == 0)
					BodyTyper.fail("E1024", 'MessagePack enum "$name" must declare at least one constructor',
						declaration.span);
				for (wireCase in cases)
					for (parameter in wireCase.caseDecl.params)
						collectType(session, parameter, classes, enums, reachable, visiting, path, origin,
							wireCase.caseDecl.span);
			default:
		}
		path.pop();
		visiting.remove(key);
		reachable.set(key, {type: type, origin: origin, span: span});
	}

	function serializableFields(session:TypingSession, declaration:TypedClass):Array<WireField> {
		var result:Array<WireField> = [], ids:Map<Int, TypedField> = [];
		for (field in declaration.fields) {
			if (field.isStatic)
				continue;
			var wireField = field;
			for (metadata in field.metadata)
				if (metadata.name == "optional") {
					wireField = {
						name: field.name, metadata: field.metadata, type: TNullable(field.type),
						initializer: field.initializer, inlineValue: field.inlineValue,
						readAccess: field.readAccess, writeAccess: field.writeAccess,
						isStatic: field.isStatic, isInline: field.isInline, isFinal: field.isFinal,
						span: field.span
					};
					break;
				}
			if (!hasDirectStorage(field))
				BodyTyper.fail("E1024",
					'MessagePack record field "${declaration.name}.${field.name}" must have direct storage',
					field.span);
			if (!isRequestType(session, field.type))
				BodyTyper.fail("E1024",
					'MessagePack record field "${declaration.name}.${field.name}" has unsupported type "${field.type}"',
					field.span);
			if (field.initializer != null && !isWireDefaultExpression(field.initializer))
				BodyTyper.fail("E1024",
					'MessagePack record field "${declaration.name}.${field.name}" has an unsupported wire default; use a literal, null, enum constructor, or simple array/map literal',
					field.span);
			var id = memberId(field.metadata, declaration.name + "." + field.name, field.span);
			if (id != 0 && ids.exists(id)) {
				var previous = ids.get(id);
				if (previous == null)
					throw new InternalError('Missing MessagePack record field for @:id($id)');
				BodyTyper.fail("E1024",
					'MessagePack record fields "${declaration.name}.${previous.name}" and "${declaration.name}.${field.name}" use duplicate @:id($id)',
					field.span);
			}
			ids.set(id, field);
			result.push({field: wireField, id: id});
		}
		return orderFields(result, declaration.name);
	}

	function recordFields(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>,
			span:SourceSpan):Array<WireField>
		return switch type {
			case TInstance(NominalKind.Class, name, _): serializableFields(session, requiredClass(classes, name, span));
			case TAnonymous(_, _): anonymousWireFields(session, type, span);
			default: throw new InternalError('No wire record fields for "$type"');
		};

	public static function memberId(metadata:Array<AstMetadata>, name:String, span:SourceSpan):Int {
		var id = 0;
		for (annotation in metadata) {
			if (annotation.name != "id")
				continue;
			if (id != 0)
				BodyTyper.fail("E1024", 'Wire member "$name" cannot declare @:id more than once', annotation.span);
			if (annotation.arguments.length != 1)
				BodyTyper.fail("E1024", '@:id requires exactly one integer argument', annotation.span);
			switch annotation.arguments[0] {
				case compiler.syntax.Ast.AstExpression.IntegerLiteral(value, _):
					id = value;
				default:
					BodyTyper.fail("E1024", '@:id requires an integer literal argument', annotation.span);
			}
			if (id <= 0)
				BodyTyper.fail("E1024", '@:id must be a positive integer', span);
		}
		return id;
	}

	function wireEnumCases(declaration:TypedEnum, span:SourceSpan):Array<WireEnumCase> {
		var result:Array<WireEnumCase> = [], ids:Map<Int, TypedEnumCase> = [];
		for (index in 0...declaration.cases.length) {
			var caseDecl = declaration.cases[index];
			var id = memberId(caseDecl.metadata, declaration.name + "." + caseDecl.name, caseDecl.span);
			if (id != 0 && ids.exists(id)) {
				var previous = ids.get(id);
				if (previous == null)
					throw new InternalError('Missing MessagePack enum constructor for @:id($id)');
				BodyTyper.fail("E1024",
					'MessagePack enum "${declaration.name}" constructors "${previous.name}" and "${caseDecl.name}" use duplicate @:id($id)',
					caseDecl.span);
			}
			ids.set(id, caseDecl);
			result.push({caseDecl: caseDecl, index: index, id: id});
		}
		if (result.length > 0) {
			var named = !Lambda.exists(result, member -> member.id != 0);
			for (member in result)
				checkKeyMode(named, member.id, declaration.name + "." + member.caseDecl.name, member.caseDecl.span);
		}
		return result;
	}

	function intComparator(request:WireCodecRequest):TypedFunction {
		var left = local("left", TInt, request.span),
			right = local("right", TInt, request.span),
			result = new TypedExpression(TConditional(new TypedExpression(TLess(left, right), TBool, request.span),
				intLiteral(-1, request.span),
				new TypedExpression(TConditional(new TypedExpression(TLess(right, left), TBool, request.span),
				intLiteral(1, request.span),
				intLiteral(0, request.span)),
				TInt, request.span)),
				TInt, request.span);
		return generatedFunction(intCompareName(), [{name: "left", type: TInt}, {name: "right", type: TInt}], TInt,
			[TReturn(result, request.span)], request, "map-int-compare", TInt);
	}

	function intCompareName():String
		return jsonMode ? "$json:map-int-compare" : INT_COMPARE_NAME;

	function stringCompareName():String
		return jsonMode ? "$json:map-string-compare" : STRING_COMPARE_NAME;

	function stringComparator(request:WireCodecRequest):TypedFunction {
		var left = local("left", TString, request.span),
			right = local("right", TString, request.span),
			result = new TypedExpression(TCall("haxeon.wire.MessagePackWriter.compareUtf8", [left, right]), TInt,
				request.span);
		return generatedFunction(stringCompareName(), [{name: "left", type: TString}, {name: "right", type: TString}],
			TInt, [TReturn(result, request.span)],
			request, "map-string-compare", TString);
	}

	function enumComparatorName(type:CompilerType):String
		return (jsonMode ? "$json:map-enum-compare:" : ENUM_COMPARE_PREFIX) + typeKey(type);

	function enumKeyExpression(value:TypedExpression, cases:Array<WireEnumCase>, span:SourceSpan):TypedExpression {
		var named = cases[0].id == 0;
		var result = named ? stringLiteral("", span) : intLiteral(0, span);
		for (caseIndex in 0...cases.length) {
			var wireCase = cases[cases.length - caseIndex - 1],
				condition = new TypedExpression(TEqual(new TypedExpression(TEnumIndex(value), TInt, span),
					intLiteral(wireCase.index, span)), TBool, span);
			result = new TypedExpression(TConditional(condition, keyLiteral(wireCase.id, wireCase.caseDecl.name, span),
				result), result.type, span);
		}
		return result;
	}

	function enumComparator(type:CompilerType, declaration:TypedEnum, request:WireCodecRequest):TypedFunction {
		var cases = wireEnumCases(declaration, request.span),
			left = local("left", type, request.span),
			right = local("right", type, request.span),
			leftKey = enumKeyExpression(left, cases, request.span),
			rightKey = enumKeyExpression(right, cases, request.span),
			result = leftKey.type == TString
				? new TypedExpression(TCall("haxeon.wire.MessagePackWriter.compareUtf8", [leftKey, rightKey]), TInt,
				request.span)
				: new TypedExpression(TConditional(new TypedExpression(TLess(leftKey, rightKey), TBool, request.span),
				intLiteral(-1, request.span),
				new TypedExpression(TConditional(new TypedExpression(TLess(rightKey, leftKey), TBool, request.span),
				intLiteral(1, request.span), intLiteral(0, request.span)), TInt, request.span)), TInt, request.span);
		return generatedFunction(enumComparatorName(type), [{name: "left", type: type}, {name: "right", type: type}],
			TInt, [TReturn(result, request.span)],
			request, "map-enum-compare", type);
	}

	function mapKeyComparator(type:CompilerType, span:SourceSpan):TypedExpression
		return switch type {
			case TString: new TypedExpression(TFunctionRef(stringCompareName()),
				TFunction([TString, TString], TInt, []),
				span);
			case TInt: new TypedExpression(TFunctionRef(intCompareName()), TFunction([TInt, TInt], TInt, []), span);
			case TInstance(NominalKind.Enum, _, _): new TypedExpression(TFunctionRef(enumComparatorName(type)),
				TFunction([
					type,
					type
				], TInt, []), span);
			default: throw new InternalError('No MessagePack map key comparator for "$type"');
		};

	function valueEncoder(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>,
			enums:Map<String, TypedEnum>,
			request:WireCodecRequest):TypedFunction {
		var writerType = classType(writerClassName()),
			valueType = type,
			writer = local("writer", writerType, request.span),
			value = local("value", valueType, request.span),
			statements = encodeValueStatements(session, classes, enums, writer, value, type, request.span);
		return generatedFunction(valueEncodeName(type), [
			{name: "writer", type: writerType},
			{name: "value", type: valueType}
		], TVoid, statements, request, "value-encode", type);
	}

	function encodeValueStatements(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			writer:TypedExpression,
			value:TypedExpression, type:CompilerType, span:SourceSpan):Array<TypedStatement> {
		return switch type {
			case TAbstract(_, _, representation):
				var encoded = encodeNestedValueStatements(writer,
					session.representation.boundaryCast(value, representation), representation, span);
				switch representation {
					case TArray(_), TMap(_, _), TAnonymous(_, _), TInstance(_, _, _):
						[
							TIf(isNullValue(value, type, span),
								[expressionStatement(method(writer, "writeNil", [], TVoid, span), span)], encoded, span)
						];
					default: encoded;
				}
			case TNullable(element):
				var nonNullValue = new TypedExpression(TCast(value), element, value.span);
				[
					TIf(isNullValue(value, type, span),
						[expressionStatement(method(writer, "writeNil", [], TVoid, span), span)],
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
						[
							writer,
							new TypedExpression(TIndex(value, index), element, span)
						]), TVoid, span),
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
						TVar(keysName, new TypedExpression(TNewArray(keyType, intLiteral(0, span)), keysType, span),
							span),
						TForIn(keyName, null, keysExpression, [
							expressionStatement(new TypedExpression(TArrayPush(keys, key), TInt, span), span)
						],
							span),
						expressionStatement(new TypedExpression(TArraySort(keys, comparator), TVoid, span), span),
						expressionStatement(method(writer, "writeMapHeader",
							[new TypedExpression(TArrayLength(keys), TInt, span)], TVoid, span), span),
						TVar(indexName, intLiteral(0, span), span)
					];
				var mapKey = new TypedExpression(TIndex(keys, index), keyType, span),
					mapBody = mapKeyEncodeStatements(writer, mapKey, keyType, enums, span);
				mapBody.push(expressionStatement(new TypedExpression(TCall(valueEncodeName(valueType),
					[
						writer,
						new TypedExpression(TMapGet(value, mapKey), valueType, span)
					]), TVoid, span),
					span));
				mapBody.push(TAssign(indexName, new TypedExpression(TAdd(index, intLiteral(1, span)), TInt, span),
					span));
				result.push(TWhile(new TypedExpression(TLess(index,
					new TypedExpression(TArrayLength(keys), TInt, span)), TBool, span), mapBody, span));
				result;
			case TInstance(NominalKind.Class, _, _), TAnonymous(_, _):
				var fields = recordFields(session, type, classes, span),
					result:Array<TypedStatement> = [
						expressionStatement(method(writer, recordHeader(true, fields.length == 0 || fields[0].id == 0),
							[intLiteral(fields.length, span)], TVoid,
							span), span)
					];
				for (wireField in fields) {
					var field = wireField.field,
						storageType = field.type;
					if (switch type {
						case TInstance(NominalKind.Class, _, _): true;
						default: false;
					})
						for (declaredField in requiredClass(classes, switch type {
						case TInstance(_, name, _): name;
						default: "";
					}, span).fields)
						if (declaredField.name == field.name) {
						storageType = declaredField.type;
						break;
					}
					var storedValue = new TypedExpression(TField(value, field.name), storageType, field.span),
						fieldValue = new TypedExpression(TCast(storedValue), field.type, field.span);
					result.push(writeMemberKey(writer, wireField.id, field.name, span));
					result = result.concat(encodeNestedValueStatements(writer, fieldValue, field.type, field.span));
				}
				result;
			case TInstance(NominalKind.Enum, name, _):
				var declaration = requiredEnum(enums, name, span),
					cases = wireEnumCases(declaration, span),
					result:Array<TypedStatement> = [
						expressionStatement(method(writer, recordHeader(true, cases[0].id == 0), [intLiteral(1, span)],
							TVoid, span), span)
					],
					fallback:Array<TypedStatement> = [
						TThrow(stringLiteral('Unknown MessagePack constructor for enum "$name"', span), span)
					];
				for (caseIndex in 0...cases.length) {
					var wireCase = cases[cases.length - caseIndex - 1],
						branch:Array<TypedStatement> = [
							writeMemberKey(writer, wireCase.id, wireCase.caseDecl.name, span),
							expressionStatement(method(writer, "writeArrayHeader",
								[intLiteral(wireCase.caseDecl.params.length, span)], TVoid, span), span)
						];
					for (fieldIndex in 0...wireCase.caseDecl.params.length) {
						var parameterType = wireEnumParameterType(session, name, wireCase.index, fieldIndex,
							wireCase.caseDecl.params[fieldIndex]),
							fieldValue = new TypedExpression(TEnumField(value, wireCase.index, fieldIndex),
								parameterType, span);
						branch = branch.concat(encodeNestedValueStatements(writer, fieldValue, parameterType, span));
					}
					var condition = new TypedExpression(TEqual(new TypedExpression(TEnumIndex(value), TInt, span),
						intLiteral(wireCase.index, span)), TBool,
						span);
					fallback = [TIf(condition, branch, fallback, span)];
				}
				result.concat(fallback);
			default:
				var methodName = primitiveMethod(type);
				if (methodName == null)
					throw new InternalError('No MessagePack encoder for "$type"');
				[expressionStatement(method(writer, methodName, [value], TVoid, span), span)];
		};
	}

	function encodeNestedValueStatements(writer:TypedExpression, value:TypedExpression, type:CompilerType,
			span:SourceSpan):Array<TypedStatement>
		return [
			expressionStatement(new TypedExpression(TCall(valueEncodeName(type), [writer, value]), TVoid, span), span)
		];

	function valueDecoder(session:TypingSession, type:CompilerType, classes:Map<String, TypedClass>,
			enums:Map<String, TypedEnum>,
			request:WireCodecRequest):TypedFunction {
		var readerType = classType(readerClassName()),
			reader = local("reader", readerType, request.span),
			statements:Array<TypedStatement> = [];
		switch type {
			case TAbstract(_, _, representation):
				var decoded = decodeValueExpression(session, classes, enums, reader, representation, request.span);
				var result = TReturn(session.representation.boundaryCast(decoded, type), request.span);
				switch representation {
					case TArray(_), TMap(_, _), TAnonymous(_, _), TInstance(_, _, _):
						statements.push(TIf(method(reader, "isNil", [], TBool, request.span), [
							expressionStatement(method(reader, "readNil", [], TVoid, request.span), request.span),
							TReturn(nullValue(type, request.span), request.span)
						], [result], request.span));
					default: statements.push(result);
				}
			case TNullable(element):
				var decoded = decodeValueExpression(session, classes, enums, reader, element, request.span),
					wrapped = new TypedExpression(TNullableWrap(decoded), type, request.span);
				statements.push(TIf(method(reader, "isNil", [], TBool, request.span), [
					expressionStatement(method(reader, "readNil", [], TVoid, request.span), request.span),
					TReturn(nullValue(type, request.span), request.span)
				], [TReturn(wrapped, request.span)], request.span));
			case TInstance(NominalKind.Class, _, _), TAnonymous(_, _):
				var fields = recordFields(session, type, classes, request.span),
					name = switch type {
						case TInstance(_, value, _): value;
						case TAnonymous(value, _): value;
						default: "record";
					},
						countName = "__wire_count",
						indexName = "__wire_index",
						named = fields.length == 0 || fields[0].id == 0;
				statements = readRecordHeader(reader, named, countName, request.span);
				statements.push(TVar(indexName, intLiteral(0, request.span), request.span));
				for (index in 0...fields.length) {
					var field = fields[index].field,
						defaultExpression = field.initializer == null
							&& requiresWirePresence(field.type)
							? null : (field.initializer == null ? defaultValue(field.type,
							request.span) : field.initializer);
					if (defaultExpression == null)
						statements.push(TVar(fieldLocal(index),
							nullableValueField(session, field) ? nullValue(TNullable(field.type), request.span)
							: missingFieldSentinel(field.type, request.span), request.span));
					else
						statements.push(TVar(fieldLocal(index), defaultExpression, request.span));
					if (requiresWirePresence(field.type) && field.initializer == null)
						statements.push(TVar(fieldSeenLocal(index),
							new TypedExpression(TBoolLiteral(false), TBool, request.span), request.span));
				}
				statements.push(TWhile(new TypedExpression(TLess(local(indexName, TInt, request.span),
					local(countName, TInt, request.span)), TBool,
					request.span),
					decodeMapBody(session, classes, enums, fields, reader, named, request.span), request.span));
				for (index in 0...fields.length) {
					var field = fields[index].field;
					if (requiresWirePresence(field.type) && field.initializer == null)
						statements.push(TIf(new TypedExpression(TNot(local(fieldSeenLocal(index), TBool, request.span)),
							TBool, request.span), [
								TThrow(stringLiteral('Missing required MessagePack field "${name}.${field.name}"',
									request.span), request.span)
							], [], request.span));
				}
				var declaration = switch type {
					case TAnonymous(_, _): null;
					default: requiredClass(classes, name, request.span);
				};
				var initialized:Map<String, Bool> = [],
					objectFields:Array<compiler.types.TypedAst.TypedObjectField> = [];
				for (index in 0...fields.length) {
					var wireField = fields[index].field;
					if (initialized.exists(wireField.name))
						throw new InternalError('Wire decoder initializes "${name}.${wireField.name}" twice');
					initialized.set(wireField.name, true);
					var storedType = wireField.type;
					if (declaration != null) {
						var found = false;
						for (declaredField in declaration.fields)
							if (!declaredField.isStatic && declaredField.name == wireField.name) {
								storedType = declaredField.type;
								found = true;
								break;
							}
						if (!found)
							throw new InternalError('Wire decoder has no field "${name}.${wireField.name}"');
					}
					var decoded = nullableValueField(session, wireField)
						? new TypedExpression(TCast(local(fieldLocal(index), TNullable(wireField.type), request.span)),
						wireField.type, request.span)
						: local(fieldLocal(index), wireField.type, request.span);
					objectFields.push({
						name: wireField.name,
						value: declaration == null ? decoded : new TypedExpression(TCast(decoded), storedType,
							request.span)
					});
				}
				if (declaration != null)
					for (field in declaration.fields)
						if (!field.isStatic && !initialized.exists(field.name))
							throw new InternalError('Wire decoder does not initialize "${name}.${field.name}"');
				statements.push(TReturn(new TypedExpression(TObjectLiteral(name, objectFields, false), type,
					request.span), request.span));
			case TArray(element):
				var countName = "__wire_count",
					indexName = "__wire_index",
					resultName = "__wire_result",
					resultType = TArray(element);
				statements.push(TVar(countName, method(reader, "readArrayHeader", [], TInt, request.span),
					request.span));
				statements.push(TVar(indexName, intLiteral(0, request.span), request.span));
				statements.push(TVar(resultName, new TypedExpression(TNewArray(element,
					local(countName, TInt, request.span)), resultType, request.span),
					request.span));
				statements.push(TWhile(new TypedExpression(TLess(local(indexName, TInt, request.span),
					local(countName, TInt, request.span)), TBool,
					request.span),
					decodeArrayBody(session, classes, enums, resultName, resultType, element, reader, indexName,
					request.span), request.span));
				statements.push(TReturn(local(resultName, resultType, request.span), request.span));
			case TMap(keyType, valueType):
				var countName = "__wire_count",
					indexName = "__wire_index",
					keyName = "__wire_key",
					resultName = "__wire_result",
					resultType = TMap(keyType, valueType);
				statements.push(TVar(countName, method(reader, "readMapHeader", [], TInt, request.span), request.span));
				statements.push(TVar(indexName, intLiteral(0, request.span), request.span));
				statements.push(TVar(resultName,
					new TypedExpression(TNewMap(keyType, valueType), resultType, request.span), request.span));
				statements.push(TDeclare(keyName, keyType, request.span));
				statements.push(TWhile(new TypedExpression(TLess(local(indexName, TInt, request.span),
					local(countName, TInt, request.span)), TBool,
					request.span),
					decodeMapValueBody(session, classes, enums, resultName, resultType, keyType, valueType, reader,
					keyName, indexName, request.span),
					request.span));
				statements.push(TReturn(local(resultName, resultType, request.span), request.span));
			case TInstance(NominalKind.Enum, name, _):
				statements = decodeEnumValueStatements(session, classes, enums, name, type, reader, request.span);
			default:
				var methodName = primitiveReadMethod(type);
				if (methodName == null)
					throw new InternalError('No MessagePack decoder for "$type"');
				statements.push(TReturn(method(reader, methodName, [], type, request.span), request.span));
		}
		return generatedFunction(valueDecodeName(type), [{name: "reader", type: readerType}], type, statements, request,
			"value-decode", type);
	}

	function decodeEnumValueStatements(session:TypingSession, classes:Map<String, TypedClass>,
			enums:Map<String, TypedEnum>, name:String,
			type:CompilerType, reader:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		var declaration = requiredEnum(enums, name, span),
			cases = wireEnumCases(declaration, span),
			countName = "__wire_enum_map_count",
			payloadCountName = "__wire_enum_payload_count",
			named = cases[0].id == 0,
			result = readRecordHeader(reader, named, countName, span),
			fallback:Array<TypedStatement> = [
				TThrow(stringLiteral('Unknown MessagePack constructor for enum "$name"', span), span)
			];
		result.push(TIf(new TypedExpression(TNot(new TypedExpression(TEqual(local(countName, TInt, span),
			intLiteral(1, span)), TBool, span)), TBool, span),
			[TThrow(stringLiteral('Invalid MessagePack shape for enum "$name"', span), span)], [], span));
		result = result.concat(readMemberKey(reader, named, span, jsonMode));
		result.push(TVar(payloadCountName, method(reader, "readArrayHeader", [], TInt, span), span));
		for (caseIndex in 0...cases.length) {
			var wireCase = cases[cases.length - caseIndex - 1],
				branch:Array<TypedStatement> = [
					TIf(new TypedExpression(TNot(new TypedExpression(TEqual(local(payloadCountName, TInt, span),
						intLiteral(wireCase.caseDecl.params.length, span)), TBool, span)),
						TBool, span),
						[
							TThrow(stringLiteral('Invalid MessagePack payload for enum "$name.${wireCase.caseDecl.name}"',
								span), span)
						], [], span)
				];
			var arguments:Array<TypedExpression> = [];
			for (fieldIndex in 0...wireCase.caseDecl.params.length) {
				var parameterType = wireEnumParameterType(session, name, wireCase.index, fieldIndex,
					wireCase.caseDecl.params[fieldIndex]),
					parameterName = enumParameterLocal(wireCase.index, fieldIndex),
					parameter = local(parameterName, parameterType, span);
				arguments.push(parameter);
				branch.push(TDeclare(parameterName, parameterType, span));
				branch = branch.concat(decodeValueAssignment(session, classes, enums, parameter, parameterType, reader,
					span));
			}
			branch.push(TReturn(new TypedExpression(TEnumConstruct(name, wireCase.index, arguments), type, span),
				span));
			var condition = matchesMemberKey(wireCase.id, wireCase.caseDecl.name, span);
			fallback = [TIf(condition, branch, fallback, span)];
		}
		return result.concat(fallback);
	}

	function encoder(type:CompilerType, request:WireCodecRequest):TypedFunction {
		var writerType = classType(writerClassName()),
			writerName = "__wire_writer",
			value = local("value", type, request.span),
			writer = local(writerName, writerType, request.span),
			statements:Array<TypedStatement> = [
				TVar(writerName, new TypedExpression(TNew(writerClassName(),
					[limit(DEFAULT_MAX_BYTES, request.span)], true), writerType, request.span),
					request.span),
				TExpression(new TypedExpression(TCall(valueEncodeName(type), [writer, value]), TVoid, request.span),
					request.span),
				TReturn(method(writer, jsonMode ? "getString" : "getBytes", [], jsonMode ? TString : TBytes,
					request.span), request.span)
			];
		return generatedFunction(rootEncodeName(type), [{name: "value", type: type}], jsonMode ? TString : TBytes,
			statements, request, "encode", type);
	}

	/** A reader's or writer's limit argument: they declare them `?maxDepth:Int = 64`, which is `Null<Int>`. */
	function limit(value:Int, span:SourceSpan):TypedExpression
		return new TypedExpression(TNullableWrap(intLiteral(value, span)), TNullable(TInt), span);

	function decoder(type:CompilerType, request:WireCodecRequest):TypedFunction {
		var readerType = classType(readerClassName()),
			readerName = "__wire_reader",
			resultName = "__wire_result",
			bytes = local("bytes", jsonMode ? TString : TBytes, request.span),
			reader = local(readerName, readerType, request.span),
			statements:Array<TypedStatement> = [
				TVar(readerName, new TypedExpression(TNew(readerClassName(), [
					bytes, limit(DEFAULT_MAX_CONTAINER, request.span),
					limit(DEFAULT_MAX_DEPTH, request.span), limit(DEFAULT_MAX_BYTES, request.span)
				],
					true),
					readerType, request.span),
					request.span),
				TVar(resultName, new TypedExpression(TCall(valueDecodeName(type), [reader]), type, request.span),
					request.span),
				TIf(new TypedExpression(TNot(method(reader, "atEnd", [], TBool, request.span)), TBool, request.span), [
					TThrow(stringLiteral("MessagePack value has trailing bytes", request.span), request.span)
				], [], request.span),
				TReturn(local(resultName, type, request.span), request.span)
			];
		return generatedFunction(rootDecodeName(type), [{name: "bytes", type: jsonMode ? TString : TBytes}], type,
			statements, request, "decode", type);
	}

	function decodeMapBody(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			fields:Array<WireField>,
			reader:TypedExpression, named:Bool, span:SourceSpan):Array<TypedStatement> {
		var result = readMemberKey(reader, named, span, jsonMode);
		var fallback:Array<TypedStatement> = [expressionStatement(method(reader, "skip", [], TVoid, span), span)];
		for (index in 0...fields.length) {
			var wireField = fields[fields.length - index - 1],
				field = wireField.field,
				fieldIndex = fields.length - index - 1,
				condition = matchesMemberKey(wireField.id, field.name, span),
				assignment = decodeFieldAssignment(session, classes, enums, field, fieldIndex, reader, span);
			if (requiresWirePresence(field.type) && field.initializer == null)
				assignment.push(TAssign(fieldSeenLocal(fieldIndex),
					new TypedExpression(TBoolLiteral(true), TBool, span), span));
			fallback = [TIf(condition, assignment, fallback, span)];
		}
		result = result.concat(fallback);
		result.push(TAssign("__wire_index",
			new TypedExpression(TAdd(local("__wire_index", TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	function decodeArrayBody(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			resultName:String,
			resultType:CompilerType, element:CompilerType, reader:TypedExpression, indexName:String,
			span:SourceSpan):Array<TypedStatement> {
		var target = new TypedExpression(TIndex(local(resultName, resultType, span), local(indexName, TInt, span)),
			element, span),
			result = decodeValueAssignment(session, classes, enums, target, element, reader, span);
		result.push(TAssign(indexName,
			new TypedExpression(TAdd(local(indexName, TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	function decodeMapValueBody(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			resultName:String,
			resultType:CompilerType, keyType:CompilerType, valueType:CompilerType, reader:TypedExpression,
			keyName:String, indexName:String,
			span:SourceSpan):Array<TypedStatement> {
		var key = local(keyName, keyType, span),
			map = local(resultName, resultType, span),
			target = new TypedExpression(TMapGet(map, key), valueType, span),
			result:Array<TypedStatement> = mapKeyDecodeStatements(reader, keyName, keyType, enums, span);
		result = result.concat(decodeValueAssignment(session, classes, enums, target, valueType, reader, span));
		result.push(TAssign(indexName,
			new TypedExpression(TAdd(local(indexName, TInt, span), intLiteral(1, span)), TInt, span), span));
		return result;
	}

	function decodeFieldAssignment(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			field:TypedField,
			fieldIndex:Int, reader:TypedExpression, span:SourceSpan):Array<TypedStatement> {
		if (nullableValueField(session, field)) {
			var nullable = TNullable(field.type),
				decoded = decodeValueExpression(session, classes, enums, reader, field.type, span);
			return [TAssign(fieldLocal(fieldIndex), new TypedExpression(TNullableWrap(decoded), nullable, span), span)];
		}
		return decodeValueAssignment(session, classes, enums, local(fieldLocal(fieldIndex), field.type, span),
			field.type, reader, span);
	}

	function nullableValueField(session:TypingSession, field:TypedField):Bool
		return field.initializer == null && requiresWirePresence(field.type)
			&& session.relations.isValueClass(TypeRelations.abstractRepresentation(field.type));

	function decodeValueAssignment(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			target:TypedExpression,
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

	function assignValue(target:TypedExpression, value:TypedExpression, span:SourceSpan):TypedStatement
		return switch target.expression {
			case TLocal(name): TAssign(name, value, span);
			case TIndex(array, index): TIndexAssign(array, index, value, span);
			case TMapGet(map, key): TMapAssign(map, key, value, span);
			default: throw new InternalError("MessagePack decoder target must be a local, array index, or map entry");
		};

	function decodeValueExpression(session:TypingSession, classes:Map<String, TypedClass>, enums:Map<String, TypedEnum>,
			reader:TypedExpression,
			type:CompilerType, span:SourceSpan):TypedExpression {
		return switch type {
			case TNullable(_), TArray(_), TMap(_, _), TAnonymous(_, _), TAbstract(_, _, _),
				TInstance(NominalKind.Class, _, _), TInstance(NominalKind.Enum, _, _):
				new TypedExpression(TCall(valueDecodeName(type), [reader]), type, span);
			default:
				var methodName = primitiveReadMethod(type);
				if (methodName == null)
					throw new InternalError('No MessagePack decoder for "$type"');
				method(reader, methodName, [], type, span);
		};
	}

	function defaultValue(type:CompilerType, span:SourceSpan):TypedExpression
		return switch type {
			case TInt: intLiteral(0, span);
			case TInt64: new TypedExpression(TCall("haxe.Int64.ofInt", [intLiteral(0, span)]), TInt64, span);
			case TFloat: new TypedExpression(TFloatLiteral(0.0), TFloat, span);
			case TBool: new TypedExpression(TBoolLiteral(false), TBool, span);
			case TString: stringLiteral("", span);
			case TBytes: new TypedExpression(TCall("haxe.io.Bytes.alloc", [intLiteral(0, span)]), TBytes, span);
			case TNullable(_): nullValue(type, span);
			case TArray(element): new TypedExpression(TNewArray(element, intLiteral(0, span)), type, span);
			case TMap(key, value): new TypedExpression(TNewMap(key, value), type, span);
			default: throw new InternalError('No MessagePack default for "$type"');
		};

	function missingFieldSentinel(type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TCast(nullValue(TNullable(type), span)), type, span);

	function requiresWirePresence(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.Class, _, _), TInstance(NominalKind.Enum, _, _), TAnonymous(_, _),
				TAbstract(_, _, _): true;
			default: false;
		};

	function isWireDefaultExpression(expression:TypedExpression):Bool
		return switch expression.expression {
			case TIntLiteral(_), TFloatLiteral(_), TStringLiteral(_), TBoolLiteral(_), TNullLiteral,
				TEnumLiteral(_, _): true;
			case TNullableWrap(value), TCast(value), TAbiCast(value), TParameterConversion(value, _),
				TIntToFloat(value), TIntToInt64(value),
				TFloatToInt(value):
				isWireDefaultExpression(value);
			case TEnumConstruct(_, _, arguments):
				[for (argument in arguments) if (!isWireDefaultExpression(argument)) false].length == 0;
			case TArrayLiteral(values):
				[for (value in values) if (!isWireDefaultExpression(value)) false].length == 0;
			case TMapLiteral(entries):
				[
					for (entry in entries)
						if (!isWireDefaultExpression(entry.key) || !isWireDefaultExpression(entry.value)) false
				].length == 0;
			default: false;
		};

	function isNullValue(value:TypedExpression, type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TEqual(value, nullValue(type, span)), TBool, span);

	function nullValue(type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), type, span);

	function wireEnumParameterType(session:TypingSession, name:String, constructor:Int, field:Int,
			storedType:CompilerType):CompilerType {
		var declaration = session.enumDecls.get(name);
		if (declaration == null
			|| constructor < 0
			|| constructor >= declaration.cases.length
			|| field < 0
			|| field >= declaration.cases[constructor].params.length)
			return storedType;
		if (!declaration.cases[constructor].params[field].optional)
			return storedType;
		return switch storedType {
			case TNullable(_): storedType;
			default: TNullable(storedType);
		};
	}

	function primitiveMethod(type:CompilerType):Null<String>
		return switch type {
			case TInt: "writeInt";
			case TInt64: "writeInt64";
			case TFloat: "writeFloat";
			case TBool: "writeBool";
			case TString: "writeString";
			case TBytes: "writeBinary";
			default: null;
		};

	function primitiveReadMethod(type:CompilerType):Null<String>
		return switch type {
			case TInt: "readInt";
			case TInt64: "readInt64";
			case TFloat: "readFloat";
			case TBool: "readBool";
			case TString: "readString";
			case TBytes: "readBinary";
			default: null;
		};

	function mapKeyEncodeStatements(writer:TypedExpression, key:TypedExpression, type:CompilerType,
			enums:Map<String, TypedEnum>,
			span:SourceSpan):Array<TypedStatement>
		return switch type {
			case TInstance(NominalKind.Enum, name, _):
				var declaration = requiredEnum(enums, name, span),
					cases = wireEnumCases(declaration, span);
				[
					expressionStatement(method(writer, cases[0].id == 0 ? "writeString" : "writeInt",
						[enumKeyExpression(key, cases, span)], TVoid, span), span)
				];
			default:
				[
					expressionStatement(method(writer, mapKeyMethod(type, true), [key], TVoid, span), span)
				];
		};

	function mapKeyDecodeStatements(reader:TypedExpression, keyName:String, type:CompilerType,
			enums:Map<String, TypedEnum>,
			span:SourceSpan):Array<TypedStatement>
		return switch type {
			case TInstance(NominalKind.Enum, name, _):
				var declaration = requiredEnum(enums, name, span),
					cases = wireEnumCases(declaration, span),
					fallback:Array<TypedStatement> = [
						TThrow(stringLiteral('Unknown MessagePack constructor for map key enum "$name"', span), span)
					];
				for (caseIndex in 0...cases.length) {
					var wireCase = cases[cases.length - caseIndex - 1],
						condition = matchesMemberKey(wireCase.id, wireCase.caseDecl.name, span),
						branch:Array<TypedStatement> = [
							TAssign(keyName, new TypedExpression(TEnumConstruct(name, wireCase.index, []), type, span),
								span)
						];
					fallback = [TIf(condition, branch, fallback, span)];
				}
				readMemberKey(reader, cases[0].id == 0, span, false).concat(fallback);
			default:
				[
					TAssign(keyName, method(reader, mapKeyMethod(type, false), [], type, span), span)
				];
		};

	function recordHeader(writing:Bool, named:Bool):String {
		if (jsonMode && named)
			return writing ? "writeObjectHeader" : "readObjectHeader";
		return writing ? "writeMapHeader" : "readMapHeader";
	}

	function readRecordHeader(reader:TypedExpression, named:Bool, countName:String,
			span:SourceSpan):Array<TypedStatement> {
		var header = method(reader, recordHeader(false, named), [], TInt, span);
		if (!jsonMode || named)
			return [TVar(countName, header, span)];
		// In JSON the enclosing shape distinguishes a name from a numbered string key.
		var isObject = local("__wire_object", TBool, span);
		return [
			TVar("__wire_object", method(reader, "isObject", [], TBool, span), span),
			TVar(countName, new TypedExpression(TConditional(isObject,
				method(reader, "readObjectHeader", [], TInt, span), header), TInt, span), span)
		];
	}

	function keyLiteral(id:Int, name:String, span:SourceSpan):TypedExpression
		return id == 0 ? stringLiteral(name, span) : intLiteral(id, span);

	function writeMemberKey(writer:TypedExpression, id:Int, name:String, span:SourceSpan):TypedStatement {
		var key = keyLiteral(id, name, span);
		return expressionStatement(id == 0 ? method(writer, "writeString", [key], TVoid, span)
			: jsonMode ? method(writer, "writeFieldKey", [key, stringLiteral(name, span)], TVoid, span)
			: method(writer, "writeInt", [key], TVoid, span), span);
	}

	function readMemberKey(reader:TypedExpression, named:Bool, span:SourceSpan,
			jsonRecord:Bool):Array<TypedStatement> {
		var readName = method(reader, "readString", [], TString, span);
		if (named)
			return [TVar("__wire_name", readName, span)];
		var isName = local("__wire_is_name", TBool, span),
			keyKind = jsonRecord ? local("__wire_object", TBool, span) : method(reader, "isString", [], TBool, span);
		return [
			TVar("__wire_is_name", keyKind, span),
			TVar("__wire_name", new TypedExpression(TConditional(isName, readName, stringLiteral("", span)),
				TString, span), span),
			TVar("__wire_id", new TypedExpression(TConditional(isName, intLiteral(0, span),
				method(reader, "readInt", [], TInt, span)), TInt, span), span)
		];
	}

	function matchesMemberKey(id:Int, name:String, span:SourceSpan):TypedExpression {
		var byName = new TypedExpression(TEqual(local("__wire_name", TString, span), stringLiteral(name, span)),
			TBool, span);
		if (id == 0)
			return byName;
		var byId = new TypedExpression(TEqual(local("__wire_id", TInt, span), intLiteral(id, span)), TBool, span);
		return new TypedExpression(TOr(byId, byName), TBool, span);
	}

	function mapKeyMethod(type:CompilerType, writing:Bool):String {
		var methodName = writing ? primitiveMethod(type) : primitiveReadMethod(type);
		if (methodName == null)
			throw new InternalError('No MessagePack map key method for "$type"');
		return methodName;
	}

	static function typeKey(type:CompilerType):String
		return switch type {
			case TAbstract(name, arguments, _):
				"abstract_" + nominalKey(name) + (arguments.length == 0
					? "" : "_" + [for (argument in arguments) typeSegment(typeKey(argument))].join("_"));
			case TAnonymous(name, _) if (compiler.types.Monomorphs.isOpenStructureName(name)):
				throw new InternalError('An open literal structure ($name) keyed a wire codec before its unit closed it');
			case TAnonymous(name, _): "anonymous_" + nominalKey(name);
			case TInt: "int";
			case TInt64: "int64";
			case TFloat: "float";
			case TBool: "bool";
			case TString: "string";
			case TBytes: "bytes";
			case TNullable(element): "nullable_" + typeSegment(typeKey(element));
			case TArray(element): "array_" + typeSegment(typeKey(element));
			case TMap(key, value):
				(switch key {
					case TString: "map_string_";
					case TInt: "map_int_";
					case TInstance(NominalKind.Enum, _, _): "map_enum_" + typeSegment(typeKey(key));
					default: throw new InternalError('No MessagePack map key for "$key"');
				}) + typeSegment(typeKey(value));
			case TInstance(NominalKind.Class, name, _): "class_" + nominalKey(name);
			case TInstance(NominalKind.Enum, name, _): "enum_" + nominalKey(name);
			default: throw new InternalError('No MessagePack codec key for "$type"');
		};

	static function typeSegment(key:String):String
		return key.length + ":" + key;

	static function nominalKey(name:String):String
		return StringTools.replace(StringTools.replace(name, "_", "_u"), ".", "_d");

	static function validateWireMarker(annotations:Array<AstMetadata>):Void {
		for (metadata in annotations)
			if (metadata.name == "wire") {
				if (metadata.arguments.length != 0)
					BodyTyper.fail("E1024", '@:wire does not accept arguments', metadata.span);
			}
	}

	static function isNullaryWireEnum(session:TypingSession, name:String):Bool {
		var declaration = session.enumDecls.get(name);
		if (declaration == null)
			return false;
		for (constructor in declaration.cases)
			if (constructor.params.length != 0)
				return false;
		return true;
	}

	function requiredClass(classes:Map<String, TypedClass>, name:String, span:SourceSpan):TypedClass {
		var declaration = classes.get(name);
		if (declaration == null)
			BodyTyper.fail("E1024", 'MessagePack record "$name" is not available in the typed program', span);
		return cast declaration;
	}

	function requiredEnum(enums:Map<String, TypedEnum>, name:String, span:SourceSpan):TypedEnum {
		var declaration = enums.get(name);
		if (declaration == null)
			BodyTyper.fail("E1024", 'MessagePack enum "$name" is not available in the typed program', span);
		return cast declaration;
	}

	function hasDirectStorage(field:TypedField):Bool
		return switch [field.readAccess, field.writeAccess] {
			case [GetAccess, _], [_, SetAccess], [NeverAccess, _], [_, NeverAccess]: false;
			default: true;
		};

	function classType(name:String):CompilerType
		return TInstance(NominalKind.Class, name, []);

	function local(name:String, type:CompilerType, span:SourceSpan):TypedExpression
		return new TypedExpression(TLocal(name), type, span);

	function intLiteral(value:Int, span:SourceSpan):TypedExpression
		return new TypedExpression(TIntLiteral(value), TInt, span);

	function stringLiteral(value:String, span:SourceSpan):TypedExpression
		return new TypedExpression(TStringLiteral(value), TString, span);

	function method(receiver:TypedExpression, name:String, arguments:Array<TypedExpression>, result:CompilerType,
			span:SourceSpan):TypedExpression
		return new TypedExpression(TMethodCall(receiver, receiverTypeName(receiver.type) + "." + name, arguments),
			result, span);

	function receiverTypeName(type:CompilerType):String
		return switch type {
			case TInstance(_, name, _): name;
			default: throw new InternalError('MessagePack method receiver must be a nominal class, got "$type"');
		};

	function expressionStatement(expression:TypedExpression, span:SourceSpan):TypedStatement
		return TExpression(expression, span);

	function fieldLocal(index:Int):String
		return "__wire_field_" + index;

	function fieldSeenLocal(index:Int):String
		return "__wire_field_seen_" + index;

	function enumParameterLocal(constructor:Int, field:Int):String
		return '__wire_enum_${constructor}_$field';

	function generatedFunction(name:String, arguments:Array<{name:String, type:CompilerType}>, result:CompilerType,
			statements:Array<TypedStatement>,
			request:WireCodecRequest, kind:String, type:CompilerType):TypedFunction
		return {
			name: name, role: ProviderFunction(type,
				ProviderOperations.detailed(jsonMode ? ProviderOperation.Json : ProviderOperation.Wire, kind)),
			origin: request.origin,
			originKind: compiler.types.TypedAst.FunctionOriginKind.Helper,
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
