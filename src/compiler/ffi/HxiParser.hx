package compiler.ffi;

import haxe.Int64;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiEnumValue;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiDocumentation;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiParameterDirection;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiPointerOwnership;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.documentation.Documentation.DocumentationComment;
import compiler.documentation.Documentation.DocumentationTools;

private typedef HxiToken = {
	final text:String;
	final span:SourceSpan;
}

private typedef HxiLexResult = {
	final tokens:Array<HxiToken>;
	final comments:Array<DocumentationComment>;
}

/** Parses and validates Haxeon's generated, target-specific ABI interface format. */
class HxiParser {
	static final primitives = [
		"void",
		"i8",
		"u8",
		"i16",
		"u16",
		"i32",
		"u32",
		"i64",
		"u64",
		"isize",
		"usize",
		"f32",
		"f64",
		"utf8",
		"c_char",
		"c_schar",
		"c_uchar",
		"c_bool",
		"c_short",
		"c_ushort",
		"c_int",
		"c_uint",
		"c_long",
		"c_ulong",
		"c_long_long",
		"c_ulong_long",
		"c_wchar",
		"c_size"
	];

	final source:SourceFile;
	final comments:Array<DocumentationComment>;
	final visibleDeclarations:Array<HxiDeclaration>;
	final documentation:Map<String, HxiDocumentation> = [];
	final tokens:Array<HxiToken>;
	final validateParsed:Bool;
	var position = 0;

	public static function parse(path:String, text:String, ?visibleDeclarations:Array<HxiDeclaration>):HxiInterface
		return new HxiParser(new SourceFile(path, text), visibleDeclarations).parseInterface();

	/** Parses HXI syntax without validation for callers that will validate a composed model. */
	public static function parseUnvalidated(path:String, text:String):HxiInterface
		return new HxiParser(new SourceFile(path, text), null, false).parseInterface();

	function new(source:SourceFile, ?visibleDeclarations:Array<HxiDeclaration>, validateParsed:Bool = true) {
		this.source = source;
		this.visibleDeclarations = visibleDeclarations == null ? [] : visibleDeclarations;
		this.validateParsed = validateParsed;
		var lexed = tokenize(source);
		comments = lexed.comments;
		tokens = lexed.tokens;
	}

	function parseInterface():HxiInterface {
		var start = expect("interface").span,
			name = identifier(),
			metadata = parseMetadata(["target", "library", "depends"]);
		expect("{");
		var declarations = [];
		while (!check("}"))
			declarations.push(parseDeclaration());
		var end = expect("}").span;
		if (!atEnd())
			fail('Unexpected token "${current().text}"', current().span);
		var target = metadataValue(metadata, "target", true),
			library = metadataValue(metadata, "library", false),
			dependencies = metadataStrings(metadata, "depends"),
			result = new HxiInterface(name, target, library, dependencies, declarations, start.merge(end), documentation);
		if (validateParsed)
			validate(result, visibleDeclarations);
		return result;
	}

	function parseDeclaration():HxiDeclaration {
		var start = current().span;
		var declaration = switch current().text {
			case "opaque":
				advance();
				var name = identifier(), end = expect(";").span;
				Opaque(name, start.merge(end));
			case "type":
				advance();
				var name = identifier();
				expect("=");
				var type = parseType(), end = expect(";").span;
				Alias(name, type, start.merge(end));
			case "handle": parseHandle(start);
			case "const":
				advance();
				var name = identifier();
				expect("=");
				var value = integer(), end = expect(";").span;
				Constant(name, value, start.merge(end));
			case "struct": parseStructure(start);
			case "enum": parseEnumeration(start, false);
			case "flags": parseEnumeration(start, true);
			case "callback": parseCallback(start);
			case "extern": parseFunction(start);
			default: fail('Expected HXI declaration, got "${current().text}"', current().span);
		};
		var named = declarationName(declaration);
		rememberDocumentation(named.name, named.span);
		return declaration;
	}

	function parseHandle(start:SourceSpan):HxiDeclaration {
		advance();
		var name = identifier();
		expect(":");
		var representation = parseType(), end = expect(";").span;
		return Handle(name, representation, start.merge(end));
	}

	function parseCallback(start:SourceSpan):HxiDeclaration {
		advance();
		var name = identifier();
		expect("=");
		expect("fn");
		var parameters = parseParameters(false);
		expect("->");
		var result = parseType(),
			metadata = parseMetadata(["callconv"]),
			callConvention = metadataValue(metadata, "callconv", false);
		var end = expect(";").span;
		return Callback(name, parameters, result, callConvention == null ? "cdecl" : callConvention, start.merge(end));
	}

	function parseParameters(allowDirections:Bool):Array<HxiParameter> {
		expect("(");
		var parameters:Array<HxiParameter> = [];
		if (!check(")"))
			do {
				var start = current().span, name = identifier();
				expect(":");
				var type = parseType(), metadata = parseMetadata([
					"out",
					"inout",
					"out_buffer",
					"in_array",
					"out_array",
					"borrowed",
					"owned",
					"retained"
				]), out = metadataFlag(metadata,
					"out"), inout = metadataFlag(metadata,
						"inout"), borrowed = metadataFlag(metadata,
						"borrowed"), retained = metadataFlag(metadata,
						"retained"), owned = metadataValue(metadata, "owned",
						false), bufferSize = metadataValue(metadata, "out_buffer",
						false), arrayCount = metadataValue(metadata, "in_array",
						false), outputArrayCount = metadataValue(metadata, "out_array",
						false), direction = out ? Out : inout ? InOut : bufferSize != null ? OutBuffer(bufferSize) : arrayCount != null ? InArray(arrayCount) : outputArrayCount != null ? OutArray(outputArrayCount) : In;
				if ((out ? 1 : 0)
					+ (inout ? 1 : 0)
					+ (bufferSize == null ? 0 : 1)
					+ (arrayCount == null ? 0 : 1)
					+ (outputArrayCount == null ? 0 : 1) > 1)
					fail('Parameter "$name" cannot combine output direction metadata', start);
				if (borrowed && owned != null)
					fail('Parameter "$name" cannot combine @borrowed and @owned', start);
				if (!allowDirections && (direction != In || borrowed || owned != null))
					fail('Callback parameter "$name" cannot use output direction metadata', start);
				if (!allowDirections && retained)
					fail('Callback parameter "$name" cannot use @retained', start);
				if ((borrowed || owned != null) && direction != Out)
					fail('Parameter "$name" can use @borrowed or @owned only with @out', start);
				parameters.push({
					name: name,
					type: type,
					direction: direction,
					ownership: owned != null ? Owned(owned) : borrowed ? Borrowed : Unspecified,
					retained: retained,
					span: start.merge(previous().span)
				});
			} while (match(","));
		expect(")");
		return parameters;
	}

	function parseEnumeration(start:SourceSpan, flags:Bool):HxiDeclaration {
		advance();
		var name = identifier();
		expect(":");
		var representation = parseType();
		var wideFlags = flags;
		expect("{");
		var values:Array<HxiEnumValue> = [];
		while (!check("}")) {
			var valueStart = current().span, valueName = identifier();
			expect("=");
			var value = wideFlags ? parseWideEnumExpression() : Int64.ofInt(parseEnumExpression()),
				end = expect(";").span,
				valueSpan = valueStart.merge(end);
			values.push({name: valueName, value: value, span: valueSpan});
			rememberDocumentation('$name.$valueName', valueSpan);
		}
		var end = expect("}").span;
		return Enumeration(name, representation, flags, values, start.merge(end));
	}

	function parseWideEnumExpression():Int64 {
		var value = parseWideEnumShift();
		while (match("|"))
			value = Int64.or(value, parseWideEnumShift());
		return value;
	}

	function parseWideEnumShift():Int64 {
		var value = parseWideEnumPrimary();
		while (check("<<") || check(">>")) {
			var operation = advance().text,
				shiftValue = parseWideEnumPrimary();
			if (Int64.compare(shiftValue, Int64.ofInt(0)) < 0 || Int64.compare(shiftValue, Int64.ofInt(63)) > 0)
				fail("Flag shift count must be between 0 and 63", previous().span);
			var shift = Std.parseInt(Int64.toStr(shiftValue));
			value = operation == "<<" ? Int64.shl(value, shift) : Int64.ushr(value, shift);
		}
		return value;
	}

	function parseWideEnumPrimary():Int64 {
		if (match("(")) {
			var value = parseWideEnumExpression();
			expect(")");
			return value;
		}
		if (match("-"))
			return Int64.sub(Int64.ofInt(0), parseWideEnumPrimary());
		var token = current();
		var value = Int64.ofInt(0);
		var parsed = false;
		if (isHexInteger(token.text)) {
			value = parseHex64(token.text, token.span);
			parsed = true;
		} else if (isIntegerLiteral(token.text)) {
			try {
				value = Int64.parseString(token.text);
				parsed = true;
			} catch (_:Dynamic)
				fail('Flag integer literal "${token.text}" is outside the signed 64-bit range', token.span);
		}
		if (!parsed)
			fail('Expected flag integer expression, got "${token.text}"', token.span);
		advance();
		return value;
	}

	function parseHex64(text:String, span:SourceSpan):Int64 {
		var value = Int64.ofInt(0);
		for (index in 2...text.length) {
			if (Int64.compare(Int64.ushr(value, 60), Int64.ofInt(0)) != 0)
				fail('Flag integer literal "$text" exceeds 64 bits', span);
			var code = text.charCodeAt(index),
				digit = code >= "0".code
					&& code <= "9".code ? code - "0".code : code >= "A".code
						&& code <= "F".code ? code - "A".code + 10 : code - "a".code + 10;
			value = Int64.or(Int64.shl(value, 4), Int64.ofInt(digit));
		}
		return value;
	}

	function parseEnumExpression():Int {
		var value = parseEnumShift();
		while (match("|"))
			value |= parseEnumShift();
		return value;
	}

	function parseEnumShift():Int {
		var value = parseEnumPrimary();
		while (check("<<") || check(">>")) {
			var operation = advance().text, shift = parseEnumPrimary();
			if (shift < 0 || shift > 31)
				fail("Enum shift count must be between 0 and 31", previous().span);
			value = operation == "<<" ? value << shift : value >> shift;
		}
		return value;
	}

	function parseEnumPrimary():Int {
		if (match("(")) {
			var value = parseEnumExpression();
			expect(")");
			return value;
		}
		if (match("-"))
			return -parseEnumPrimary();
		var token = current(), value:Null<Int> = null;
		if (isHexInteger(token.text))
			value = parseHex(token.text);
		else if (isIntegerLiteral(token.text))
			value = Std.parseInt(token.text);
		if (value == null)
			fail('Expected enum integer expression, got "${token.text}"', token.span);
		advance();
		return value;
	}

	static function parseHex(text:String):Int {
		var value = 0;
		for (index in 2...text.length) {
			var code = text.charCodeAt(index),
				digit = code >= "0".code
					&& code <= "9".code ? code - "0".code : code >= "A".code
						&& code <= "F".code ? code - "A".code + 10 : code - "a".code + 10;
			value = (value << 4) | digit;
		}
		return value;
	}

	function parseStructure(start:SourceSpan):HxiDeclaration {
		advance();
		var name = identifier(),
			metadata = parseMetadata(["layout"]),
			layout = metadataPair(metadata, "layout");
		if (layout == null)
			fail('Struct "$name" requires @layout(size, align)', start);
		expect("{");
		var fields:Array<HxiField> = [];
		while (!check("}")) {
			var fieldStart = current().span, fieldName = identifier();
			expect(":");
			var type = parseType(),
				fieldMetadata = parseMetadata(["offset", "borrowed", "owned", "length_field"]),
				offset = metadataInteger(fieldMetadata, "offset", true),
				borrowed = metadataFlag(fieldMetadata, "borrowed"),
				owned = metadataValue(fieldMetadata, "owned", false),
				lengthField = metadataValue(fieldMetadata, "length_field", false),
				end = expect(";").span;
			if (borrowed && owned != null)
				fail('Field "$fieldName" cannot combine @borrowed and @owned', fieldStart);
			var fieldSpan = fieldStart.merge(end);
			fields.push({
				name: fieldName,
				type: type,
				offset: offset,
				ownership: owned != null ? Owned(owned) : borrowed ? Borrowed : Unspecified,
				lengthField: lengthField,
				span: fieldSpan
			});
			rememberDocumentation('$name.$fieldName', fieldSpan);
		}
		var end = expect("}").span;
		return Structure(name, layout[0], layout[1], fields, start.merge(end));
	}

	function parseFunction(start:SourceSpan):HxiDeclaration {
		expect("extern");
		expect("fn");
		var name = identifier();
		var parameters = parseParameters(true);
		expect("->");
		var result = parseType(),
			metadata = parseMetadata(["symbol", "leaf", "borrowed", "owned", "length", "callconv"]),
			symbol = metadataValue(metadata, "symbol", false),
			leaf = metadataFlag(metadata, "leaf"),
			borrowed = metadataFlag(metadata, "borrowed"),
			owned = metadataValue(metadata, "owned", false),
			length = metadataValue(metadata, "length", false),
			callConvention = metadataValue(metadata, "callconv", false),
			end = expect(";").span;
		if (borrowed && owned != null)
			fail('Function "$name" cannot combine @borrowed and @owned', start);
		if ((borrowed || owned != null || length != null) && !pointerLike(result))
			fail('Pointer result metadata on "$name" requires a pointer return type', start);
		return Function(name, parameters, result, symbol, leaf, callConvention == null ? "cdecl" : callConvention, {
			ownership: owned != null ? Owned(owned) : borrowed ? Borrowed : Unspecified,
			length: length
		}, start.merge(end));
	}

	static function pointerLike(type:HxiType):Bool
		return switch type {
			case Pointer(_): true;
			case Primitive("utf8"): true;
			case Nullable(element) | Const(element): pointerLike(element);
			case _: false;
		};

	function parseType():HxiType {
		var name = identifier();
		if (name == "ptr" || name == "const" || name == "nullable") {
			expect("<");
			var element = parseType();
			expect(">");
			return switch name {
				case "ptr": Pointer(element);
				case "nullable": Nullable(element);
				default: Const(element);
			};
		}
		if (name == "array") {
			expect("<");
			var element = parseType();
			expect(",");
			var length = Std.parseInt(integer());
			expect(">");
			if (length <= 0)
				fail("Array length must be positive", previous().span);
			return Array(element, length);
		}
		return primitives.indexOf(name) >= 0 ? Primitive(name) : Named(name);
	}

	public static function validate(value:HxiInterface, visible:Array<HxiDeclaration>):Void {
		var names:Map<String, SourceSpan> = [],
			declarationsByName:Map<String, HxiDeclaration> = [],
			visibleNames:Map<String, Bool> = [];
		for (declaration in visible) {
			var visibleName = declarationName(declaration);
			if (names.exists(visibleName.name))
				fail('Duplicate visible HXI declaration "${visibleName.name}"', visibleName.span);
			names.set(visibleName.name, visibleName.span);
			declarationsByName.set(visibleName.name, declaration);
			visibleNames.set(visibleName.name, true);
		}
		for (declaration in value.declarations) {
			var named = declarationName(declaration);
			if (names.exists(named.name) && !visibleNames.exists(named.name))
				fail('Duplicate HXI declaration "${named.name}"', named.span);
			names.set(named.name, named.span);
			declarationsByName.set(named.name, declaration);
		}
		validateAliasCycles(value.declarations);
		var abi = HxiAbi.forInterface(value, declarationsByName);
		for (declaration in value.declarations)
			switch declaration {
				case Opaque(_, _) | Constant(_, _, _):
				case Alias(_, type, span):
					validateType(type, names, declarationsByName, span, false);
				case Handle(name, representation, span):
					validateType(representation, names, declarationsByName, span, false);
					switch abi.classify(representation) {
						case IntegerValue(32, Unsigned):
						case _: fail('Handle "$name" requires an unsigned 32-bit representation', span);
					}
				case Structure(name, size, align, fields, span):
					if (size <= 0 || align <= 0 || (align & (align - 1)) != 0 || size % align != 0)
						fail('Struct "$name" has invalid layout', span);
					var fieldNames:Map<String, Bool> = [];
					var ranges:Array<{start:Int, end:Int, name:String}> = [];
					for (field in fields) {
						if (fieldNames.exists(field.name))
							fail('Duplicate field "${field.name}" in struct "$name"', field.span);
						fieldNames.set(field.name, true);
						var layout = typeLayout(field.type, abi, declarationsByName, []);
						if (layout == null)
							fail('Field "${field.name}" in struct "$name" has no fixed C layout', field.span);
						if (field.offset == null || field.offset < 0 || layout.align > align || field.offset % layout.align != 0
							|| field.offset > size - layout.size)
							fail('Field "${field.name}" has an invalid offset for struct "$name"', field.span);
						for (range in ranges)
							if (field.offset < range.end && field.offset + layout.size > range.start)
								fail('Field "${field.name}" overlaps field "${range.name}" in struct "$name"', field.span);
						ranges.push({start: field.offset, end: field.offset + layout.size, name: field.name});
						validateType(field.type, names, declarationsByName, field.span, false);
						if (field.lengthField != null) {
							if (field.ownership != Borrowed
								|| (!bytePointerLike(field.type, declarationsByName)
									&& structurePointerType(field.type, declarationsByName) == null))
								fail('@length_field on "${field.name}" requires a borrowed byte, void, or structure pointer', field.span);
							var length = Lambda.find(fields, candidate -> candidate.name == field.lengthField);
							if (length == null)
								fail('@length_field on "${field.name}" references missing field "${field.lengthField}"', field.span);
							switch abi.classify(length.type) {
								case IntegerValue(32 | 64, Unsigned):
								case _:
									fail('@length_field on "${field.name}" requires an unsigned 32- or 64-bit length field', length.span);
							}
						}
						switch field.ownership {
							case Owned(_): fail('Owned pointer field "${field.name}" is not supported; keep ownership in a separate handle', field.span);
							case Borrowed:
								if (field.lengthField == null
									&& !opaquePointerLike(field.type,
										declarationsByName)) fail('@borrowed field "${field.name}" requires a pointer to an opaque type', field.span);
							case Unspecified:
						}
					}
				case Enumeration(name, representation, flags, values, span):
					validateType(representation, names, declarationsByName, span, false);
					var integer = switch abi.classify(representation) {
						case IntegerValue(bits, sign) if ((!flags && bits <= 32) || (flags && bits <= 64 && sign == Unsigned)):
							{bits: bits, signed: sign == Signed};
						case _:
							fail(flags ? 'Flags "$name" require an unsigned 8/16/32/64-bit integer representation' : 'Enum "$name" requires an 8/16/32-bit integer representation',
								span);
					};
					var valueNames:Map<String, Bool> = [],
						seenValues:Map<String, String> = [];
					for (entry in values) {
						if (valueNames.exists(entry.name))
							fail('Duplicate value "${entry.name}" in enum "$name"', entry.span);
						valueNames.set(entry.name, true);
						if (!flags && integer.bits < 32) {
							var minimum = integer.signed ? -(1 << (integer.bits - 1)) : 0;
							var maximum = integer.signed ? (1 << (integer.bits - 1)) - 1 : (1 << integer.bits) - 1;
							if (Int64.compare(entry.value, Int64.ofInt(minimum)) < 0
								|| Int64.compare(entry.value, Int64.ofInt(maximum)) > 0)
								fail('Value "${entry.name}" is outside the representation of enum "$name"', entry.span);
						}
						var key = Int64.toStr(entry.value);
						if (seenValues.exists(key))
							fail('Value "${entry.name}" duplicates "${seenValues.get(key)}" in enum "$name"', entry.span);
						seenValues.set(key, entry.name);
					}
					if (flags) {
						var knownBits = Int64.ofInt(0),
							zero = Int64.ofInt(0),
							one = Int64.ofInt(1),
							mask = integer.bits == 64 ? Int64.ofInt(-1) : Int64.sub(Int64.shl(one, integer.bits), one);
						for (entry in values) {
							var minimum = integer.bits == 32 ? Int64.parseString("-2147483648") : zero,
								maximum = integer.bits == 64 ? Int64.parseString("9223372036854775807") : Int64.sub(Int64.shl(one, integer.bits), one);
							if (integer.bits != 64 && (Int64.compare(entry.value, minimum) < 0 || Int64.compare(entry.value, maximum) > 0))
								fail('Flag value "${entry.name}" is outside the representation of flags "$name"', entry.span);
							var value = Int64.and(entry.value, mask);
							if (Int64.compare(value, zero) != 0 && Int64.compare(Int64.and(value, Int64.sub(value, one)), zero) == 0)
								knownBits = Int64.or(knownBits, value);
						}
						for (entry in values) {
							var value = Int64.and(entry.value, mask);
							if (Int64.compare(Int64.and(value, Int64.xor(knownBits, Int64.ofInt(-1))), zero) != 0)
								fail('Flag value "${entry.name}" contains bits not declared by a single-bit flag in "$name"', entry.span);
						}
					}
				case Callback(name, parameters, result, callConvention, span):
					validateCallConvention(name, callConvention, abi, span);
					if (parameters.length > 16)
						fail('Callback "$name" exceeds the 16 argument limit', span);
					for (parameter in parameters)
						validateCallbackType(parameter.type, abi, parameter.span, false);
					validateCallbackType(result, abi, span, true);
				case Function(name, parameters, result, _, _, callConvention, resultPolicy, span):
					validateCallConvention(name, callConvention, abi, span);
					var outputBuffer:Null<{name:String, sizeParameter:String, span:SourceSpan}> = null,
						outputArray:Null<{name:String, countParameter:String, span:SourceSpan}> = null;
					for (parameter in parameters) {
						validateType(parameter.type, names, declarationsByName, parameter.span, false);
						if (parameter.retained)
							switch abi.classify(parameter.type) {
								case CallbackValue(_, _, _, _):
								case _: fail('Parameter "${parameter.name}" can use @retained only with a callback type', parameter.span);
							}
						switch parameter.direction {
							case OutBuffer(sizeParameter):
								if (outputBuffer != null)
									fail('Function "$name" cannot declare more than one output buffer', parameter.span);
								if (!bytePointerLike(parameter.type, declarationsByName))
									fail('Output buffer "${parameter.name}" requires a byte pointer', parameter.span);
								if (!nullablePointer(parameter.type))
									fail('Output buffer "${parameter.name}" must be nullable for its size query', parameter.span);
								outputBuffer = {name: parameter.name, sizeParameter: sizeParameter, span: parameter.span};
							case OutArray(countParameter):
								if (outputArray != null)
									fail('Function "$name" cannot declare more than one output array', parameter.span);
								if (!nullablePointer(parameter.type) || !utf8ArrayPointer(parameter.type))
									fail('Output array "${parameter.name}" requires a nullable pointer to a UTF-8 pointer array', parameter.span);
								outputArray = {name: parameter.name, countParameter: countParameter, span: parameter.span};
							case Out | InOut:
								if (!pointerLike(parameter.type))
									fail('Output parameter "${parameter.name}" requires a pointer type', parameter.span);
								if (switch parameter.type {
										case Nullable(_): true;
										case _: false;
									})
									fail('Output parameter "${parameter.name}" cannot be nullable', parameter.span);
								validateOutputType(parameter.name, parameter.type, parameter.ownership, abi, parameter.span);
							case InArray(countParameter):
								if (structurePointerType(parameter.type, declarationsByName) == null
									&& !utf8ArrayPointer(parameter.type)
									&& !bytePointerLike(parameter.type, declarationsByName))
									fail('Input array "${parameter.name}" requires a byte, structure, or UTF-8 pointer array', parameter.span);
								var count = Lambda.find(parameters, candidate -> candidate.name == countParameter);
								if (count == null)
									fail('Input array "${parameter.name}" references missing count parameter "$countParameter"', parameter.span);
								switch abi.classify(count.type) {
									case IntegerValue(32, Unsigned):
									case _: fail('Input array "${parameter.name}" requires an unsigned 32-bit count parameter', count.span);
								}
							case In:
						}
					}
					if (outputArray != null)
						validateOutputArray(name, outputArray, parameters, abi, span);
					if (outputBuffer != null)
						validateOutputBuffer(name, outputBuffer, parameters, abi, span);
					if (outputArray != null && outputBuffer != null)
						fail('Function "$name" cannot combine an output array with an output buffer', span);
					validateType(result, names, declarationsByName, span, true);
					switch abi.classify(result, true) {
						case CallbackValue(_, _, _, _): fail('Function "$name" cannot return a callback handle yet', span);
						case _:
					}
					if (resultPolicy.length != null && !bytePointerLike(result, declarationsByName))
						fail('@length on "$name" requires a pointer to byte-sized data or void', span);
			}
		validatePointerResultContracts(value, declarationsByName, abi);
	}

	static function validatePointerResultContracts(value:HxiInterface, declarations:Map<String, HxiDeclaration>, abi:HxiAbi):Void {
		for (declaration in value.declarations)
			switch declaration {
				case Function(name, parameters, result, _, _, callConvention, resultPolicy, span):
					switch resultPolicy.ownership {
						case Owned(releaseSymbol):
							validateReleaseFunction(value, name, result, releaseSymbol, declarations, span);
						case Borrowed | Unspecified:
					}
					for (parameter in parameters)
						switch parameter.ownership {
							case Owned(releaseSymbol):
								var outputValue = pointerPointee(parameter.type, declarations);
								if (outputValue == null)
									fail('Owned output parameter "${parameter.name}" must point to a typed opaque pointer', parameter.span);
								validateReleaseFunction(value, '$name.${parameter.name}', outputValue, releaseSymbol, declarations, parameter.span);
							case Borrowed | Unspecified:
						}
					if (resultPolicy.length != null)
						validateLengthFunction(value, name, parameters, callConvention, resultPolicy.length, declarations, abi, span);
				case _:
			}
	}

	static function validateReleaseFunction(value:HxiInterface, owner:String, result:HxiType, releaseSymbol:String, declarations:Map<String, HxiDeclaration>,
			span:SourceSpan):Void {
		var release = referencedFunction(value, owner, "release", releaseSymbol, span);
		switch release {
			case Function(releaseName, parameters, releaseResult, _, _, callConvention, _, releaseSpan):
				var resultPointee = pointerPointee(result, declarations),
					releasePointee = parameters.length == 1 ? pointerPointee(parameters[0].type, declarations) : null,
					returnsVoid = switch releaseResult {
						case Primitive("void"): true;
						case _: false;
					},
					matchesPointee = resultPointee != null
						&& releasePointee != null
						&& (canonicalTypeKey(releasePointee, declarations) == canonicalTypeKey(Primitive("void"), declarations)
							|| canonicalTypeKey(resultPointee, declarations) == canonicalTypeKey(releasePointee, declarations));
				if (callConvention != "cdecl" || parameters.length != 1 || parameters[0].direction != In || !matchesPointee || !returnsVoid)
					fail('Release function "$releaseName" for owned result "$owner" must be cdecl, accept one compatible input pointer, and return void',
						releaseSpan);
			case _:
				fail('Internal error resolving release symbol "$releaseSymbol"', span);
		}
	}

	static function validateLengthFunction(value:HxiInterface, owner:String, parameters:Array<HxiParameter>, callConvention:String, lengthSymbol:String,
			declarations:Map<String, HxiDeclaration>, abi:HxiAbi, span:SourceSpan):Void {
		var length = referencedFunction(value, owner, "length", lengthSymbol, span);
		switch length {
			case Function(lengthName, lengthParameters, lengthResult, _, _, lengthCallConvention, _, lengthSpan):
				if (lengthCallConvention != callConvention)
					fail('Length function "$lengthName" for "$owner" must use calling convention "$callConvention"', lengthSpan);
				if (lengthParameters.length != parameters.length)
					fail('Length function "$lengthName" for "$owner" must accept the same arguments', lengthSpan);
				for (index in 0...parameters.length)
					if (canonicalTypeKey(parameters[index].type, declarations) != canonicalTypeKey(lengthParameters[index].type, declarations))
						fail('Argument ${index + 1} of length function "$lengthName" for "$owner" must match the pointer function ABI type',
							lengthParameters[index].span);
				switch abi.classify(lengthResult, true) {
					case IntegerValue(bits, Unsigned) if (bits == abi.pointerBits):
					case _: fail('Length function "$lengthName" for "$owner" must return target-sized unsigned size_t', lengthSpan);
				}
			case _:
				fail('Internal error resolving length symbol "$lengthSymbol"', span);
		}
	}

	static function referencedFunction(value:HxiInterface, owner:String, role:String, symbol:String, span:SourceSpan):HxiDeclaration {
		if (symbol.length == 0)
			fail('@$role on "$owner" requires a non-empty native function symbol', span);
		var found:Null<HxiDeclaration> = null;
		for (declaration in value.declarations)
			switch declaration {
				case Function(name, _, _, declaredSymbol, _, _, _, _) if ((declaredSymbol == null ? name : declaredSymbol) == symbol):
					if (found != null)
						fail('Native $role symbol "$symbol" referenced by "$owner" is ambiguous in interface "${value.name}"', span);
					found = declaration;
				case _:
			}
		if (found == null)
			fail('Native $role symbol "$symbol" referenced by "$owner" must name a function declared in interface "${value.name}"', span);
		return found;
	}

	static function pointerPointee(type:HxiType, declarations:Map<String, HxiDeclaration>):Null<HxiType>
		return switch type {
			case Const(element) | Nullable(element): pointerPointee(element, declarations);
			case Pointer(element): element;
			case Primitive("utf8"): Primitive("c_char");
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): pointerPointee(target, declarations);
					case _: null;
				}
			case _: null;
		};

	static function canonicalTypeKey(type:HxiType, declarations:Map<String, HxiDeclaration>):String
		return switch type {
			case Primitive(name): 'primitive:$name';
			case Named(name):
				switch declarations.get(name) {
					case Alias(_, target, _): canonicalTypeKey(target, declarations);
					case _: 'named:$name';
				}
			case Pointer(element): 'pointer<${canonicalTypeKey(element, declarations)}>';
			case Nullable(element): 'nullable<${canonicalTypeKey(element, declarations)}>';
			case Const(element): 'const<${canonicalTypeKey(element, declarations)}>';
			case Array(element, length): 'array<${canonicalTypeKey(element, declarations)},$length>';
		};

	static function validateOutputType(name:String, type:HxiType, ownership:HxiPointerOwnership, abi:HxiAbi, span:SourceSpan):Void {
		var pointee = switch type {
			case Pointer(value):
				switch value {
					case Const(_): fail('Output parameter "$name" cannot point to const data', span);
					case _: value;
				}
			case _: return;
		};
		var classified = try abi.classify(pointee) catch (error:Dynamic) {
			fail(Std.string(error), span);
			VoidValue;
		};
		switch classified {
			case IntegerValue(_, _) | EnumerationValue(_, _, _) | HandleValue(_) | FloatValue(_) | AggregateValue(_, _, _):
				if (ownership != Unspecified)
					fail('Output parameter "$name" ownership metadata requires a pointer to an opaque handle', span);
			case PointerValue(_, _, opaquePointee, _) if (opaquePointee != null):
				switch ownership {
					case Borrowed | Owned(_):
					case Unspecified: fail('Opaque pointer output parameter "$name" requires @borrowed or @owned("release_symbol")', span);
				}
			case _:
				fail('Output parameter "$name" currently requires a scalar, fixed-structure, or explicitly owned opaque-pointer pointee', span);
		}
	}

	static function validateOutputBuffer(functionName:String, buffer:{name:String, sizeParameter:String, span:SourceSpan}, parameters:Array<HxiParameter>,
			abi:HxiAbi, span:SourceSpan):Void {
		var size:HxiParameter = null;
		for (parameter in parameters)
			if (parameter.name == buffer.sizeParameter)
				size = parameter;
		if (size == null)
			fail('Output buffer "${buffer.name}" references missing size parameter "${buffer.sizeParameter}"', buffer.span);
		if (size.direction != InOut)
			fail('Output buffer size parameter "${size.name}" must use @inout', size.span);
		var pointee = switch size.type {
			case Pointer(value): value;
			case _: fail('Output buffer size parameter "${size.name}" must be ptr<u32>', size.span);
		};
		switch abi.classify(pointee) {
			case IntegerValue(32, Unsigned):
			case _:
				fail('Output buffer size parameter "${size.name}" must be ptr<u32>', size.span);
		}
		for (parameter in parameters)
			switch parameter.direction {
				case OutBuffer(_) | In:
				case InOut if (parameter.name == size.name):
				case _:
					fail('Function "$functionName" cannot mix an output buffer with unrelated output parameters', span);
			}
	}

	static function validateOutputArray(functionName:String, array:{name:String, countParameter:String, span:SourceSpan}, parameters:Array<HxiParameter>,
			abi:HxiAbi, span:SourceSpan):Void {
		var count = Lambda.find(parameters, parameter -> parameter.name == array.countParameter);
		if (count == null)
			fail('Output array "${array.name}" references missing count parameter "${array.countParameter}"', array.span);
		if (count.direction != InOut)
			fail('Output array count parameter "${count.name}" must use @inout', count.span);
		var pointee = switch count.type {
			case Pointer(value): value;
			case _: fail('Output array count parameter "${count.name}" must be ptr<u32>', count.span);
		};
		switch abi.classify(pointee) {
			case IntegerValue(32, Unsigned):
			case _:
				fail('Output array count parameter "${count.name}" must be ptr<u32>', count.span);
		}
		for (parameter in parameters)
			switch parameter.direction {
				case OutArray(_) | In:
				case InOut if (parameter.name == count.name):
				case _:
					fail('Function "$functionName" cannot mix an output array with unrelated directed parameters', span);
			}
	}

	static function nullablePointer(type:HxiType):Bool
		return switch type {
			case Nullable(inner):
				switch inner {
					case Pointer(_): true;
					case _: false;
				}
			case _: false;
		};

	static function validateCallConvention(name:String, convention:String, abi:HxiAbi, span:SourceSpan):Void {
		if (convention != "cdecl" && convention != "stdcall" && convention != "system")
			fail('Declaration "$name" has unsupported calling convention "$convention"', span);
		if (convention == "stdcall" && abi.target.indexOf("windows") < 0 && abi.target.indexOf("mingw") < 0 && abi.target.indexOf("msvc") < 0)
			fail('Calling convention "stdcall" is only available for Windows targets', span);
	}

	static function validateCallbackType(type:HxiType, abi:HxiAbi, span:SourceSpan, allowVoid:Bool):Void
		try {
			switch abi.classify(type, allowVoid) {
				case VoidValue if (allowVoid):
				case IntegerValue(_, _) | EnumerationValue(_, _, _) | HandleValue(_) | FloatValue(_) | AggregateValue(_, _, _) | Utf8Value(_):
				case PointerValue(_, _, _, _) if (!allowVoid):
				case _:
					fail("Callbacks support scalar, aggregate, and pointer arguments with scalar, aggregate, or void results", span);
			}
		} catch (error:Dynamic) {
			fail(Std.string(error), span);
		}

	static function typeLayout(type:HxiType, abi:HxiAbi, declarations:Map<String, HxiDeclaration>, resolving:Map<String, Bool>):Null<{
		size:Int,
		align:Int
	}>
		return switch type {
			case Const(element): typeLayout(element, abi, declarations, resolving);
			case Nullable(element): pointerLike(element) ? typeLayout(element, abi, declarations, resolving) : null;
			case Pointer(_): {size: Std.int(abi.pointerBits / 8), align: Std.int(abi.pointerBits / 8)};
			case Primitive("utf8"): {size: Std.int(abi.pointerBits / 8), align: Std.int(abi.pointerBits / 8)};
			case Array(element, length): var item = typeLayout(element, abi, declarations,
					resolving); item == null || item.size > Std.int(0x7FFFFFFF / length) ? null : {size: item.size * length, align: item.align};
			case Primitive(_):
				switch abi.classify(type) {
					case IntegerValue(bits, _):
						var size = Std.int(bits / 8);
						{size: size, align: Std.int(Math.min(size, abi.pointerBits / 8))};
					case EnumerationValue(_, bits, _):
						var size = Std.int(bits / 8);
						{size: size, align: Std.int(Math.min(size, abi.pointerBits / 8))};
					case FloatValue(bits):
						var size = Std.int(bits / 8);
						{size: size, align: Std.int(Math.min(size, abi.pointerBits / 8))};
					case _: null;
				}
			case Named(name):
				if (resolving.exists(name)) null; else {
					resolving.set(name, true);
					var result = switch declarations.get(name) {
						case Alias(_, target, _): typeLayout(target, abi, declarations, resolving);
						case Handle(_, _, _): {size: 4, align: 4};
						case Enumeration(_, representation, _, _, _): typeLayout(representation, abi, declarations, resolving);
						case Structure(_, size, align, _, _): {size: size, align: align};
						case _: null;
					};
					resolving.remove(name);
					result;
				}
		};

	static function validateAliasCycles(declarations:Array<HxiDeclaration>):Void {
		var aliases:Map<String, {type:HxiType, span:SourceSpan}> = [];
		for (declaration in declarations)
			switch declaration {
				case Alias(name, type, span):
					aliases.set(name, {type: type, span: span});
				case _:
			}
		var visiting:Map<String, Bool> = [], complete:Map<String, Bool> = [];
		for (name in aliases.keys())
			visitAlias(name, aliases, visiting, complete);
	}

	static function visitAlias(name:String, aliases:Map<String, {type:HxiType, span:SourceSpan}>, visiting:Map<String, Bool>, complete:Map<String, Bool>):Void {
		if (complete.exists(name))
			return;
		var alias = aliases.get(name);
		if (alias == null)
			return;
		if (visiting.exists(name))
			fail('Cyclic HXI type alias "$name"', alias.span);
		visiting.set(name, true);
		visitTypeAliases(alias.type, aliases, visiting, complete);
		visiting.remove(name);
		complete.set(name, true);
	}

	static function bytePointerLike(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Nullable(element) | Const(element): bytePointerLike(element, names);
			case Pointer(element): byteElement(element, names);
			case _: false;
		};

	static function structurePointerType(type:HxiType, names:Map<String, HxiDeclaration>):Null<String>
		return switch type {
			case Nullable(element) | Const(element): structurePointerType(element, names);
			case Pointer(element): structureElementType(element, names);
			case _: null;
		};

	static function structureElementType(type:HxiType, names:Map<String, HxiDeclaration>):Null<String>
		return switch type {
			case Const(element): structureElementType(element, names);
			case Named(name):
				switch names.get(name) {
					case Structure(_, _, _, _, _): name;
					case Alias(_, target, _): structureElementType(target, names);
					case _: null;
				}
			case _: null;
		};

	static function utf8ArrayPointer(type:HxiType):Bool
		return switch type {
			case Const(element) | Nullable(element): utf8ArrayPointer(element);
			case Pointer(element): utf8ArrayElement(element);
			case _: false;
		};

	static function utf8ArrayElement(type:HxiType):Bool
		return switch type {
			case Const(element): utf8ArrayElement(element);
			case Primitive("utf8"): true;
			case _: false;
		};

	static function opaquePointerLike(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Nullable(element) | Const(element): opaquePointerLike(element, names);
			case Pointer(element): opaqueElement(element, names);
			case _: false;
		};

	static function opaqueElement(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Const(element): opaqueElement(element, names);
			case Named(name):
				switch names.get(name) {
					case Opaque(_, _): true;
					case Alias(_, target, _): opaqueElement(target, names);
					case _: false;
				}
			case _: false;
		};

	static function byteElement(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Const(element): byteElement(element, names);
			case Primitive("void" | "i8" | "u8" | "c_char" | "c_schar" | "c_uchar"): true;
			case Named(name):
				switch names.get(name) {
					case Alias(_, target, _): byteElement(target, names);
					case _: false;
				}
			case _: false;
		};

	static function visitTypeAliases(type:HxiType, aliases:Map<String, {type:HxiType, span:SourceSpan}>, visiting:Map<String, Bool>,
			complete:Map<String, Bool>):Void
		switch type {
			case Named(name) if (aliases.exists(name)):
				visitAlias(name, aliases, visiting, complete);
			case Pointer(element) | Nullable(element) | Const(element) | Array(element, _):
				visitTypeAliases(element, aliases, visiting, complete);
			case _:
		}

	static function validateType(type:HxiType, names:Map<String, SourceSpan>, declarations:Map<String, HxiDeclaration>, span:SourceSpan, allowVoid:Bool):Void
		switch type {
			case Primitive("void") if (!allowVoid):
				fail("Void is not valid in this ABI position", span);
			case Primitive(_):
			case Named(name) if (!names.exists(name)):
				fail('Unknown HXI type "$name"', span);
			case Named(_):
			case Pointer(element):
				validateType(element, names, declarations, span, true);
			case Nullable(element):
				switch element {
					case Pointer(_):
					case Primitive("utf8"):
					case Named(name):
						switch declarations.get(name) {
							case Callback(_, _, _, _, _):
							case _: fail("nullable<> requires a pointer or callback type", span);
						}
					default: fail("nullable<> requires a pointer or callback type", span);
				}
				validateType(element, names, declarations, span, false);
			case Const(element):
				validateType(element, names, declarations, span, allowVoid);
			case Array(element, _):
				validateType(element, names, declarations, span, false);
		}

	static function declarationName(value:HxiDeclaration):{name:String, span:SourceSpan}
		return switch value {
			case Opaque(name, span) | Alias(name, _, span) | Handle(name, _, span) | Constant(name, _, span) | Structure(name, _, _, _, span) |
				Enumeration(name, _, _, _, span) | Callback(name, _, _, _, span) | Function(name, _, _, _, _, _, _, span):
				{name: name, span: span};
		}

	function rememberDocumentation(name:String, span:SourceSpan):Void {
		var value = DocumentationTools.forSpan(source, comments, span);
		if (value.raw.length > 0)
			documentation.set(name, {
				raw: value.raw,
				lines: value.lines,
				source: projectionDocumentation(value.lines),
				indentedSource: projectionDocumentation(value.lines, "\t")
			});
	}

	static function projectionDocumentation(lines:Array<String>, indent:String = ""):String {
		var output = new StringBuf();
		output.add(indent + "/**\n");
		for (line in lines)
			output.add(indent + " *" + (line.length == 0 ? "" : " " + line) + "\n");
		output.add(indent + " */\n");
		return output.toString();
	}

	function parseMetadata(allowed:Array<String>):Map<String, Array<String>> {
		var result:Map<String, Array<String>> = [];
		while (match("@")) {
			var name = identifier(), values:Array<String> = [];
			if (allowed.indexOf(name) < 0)
				fail('Unsupported @$name metadata', previous().span);
			if (match("(")) {
				if (!check(")"))
					do {
						if (!checkString() && !isIntegerLiteral(current().text))
							fail("Metadata values must be strings or integers", current().span);
						values.push(advance().text);
					} while (match(","));
				expect(")");
			}
			if (result.exists(name))
				fail('Duplicate @$name metadata', previous().span);
			result.set(name, values);
		}
		return result;
	}

	function metadataValue(values:Map<String, Array<String>>, name:String, required:Bool):Null<String> {
		var entry = values.get(name);
		if (entry == null) {
			if (required)
				fail('Interface requires @$name("...")', current().span);
			return null;
		}
		if (entry.length != 1)
			fail('@$name requires one value', current().span);
		if (!StringTools.startsWith(entry[0], '"'))
			fail('@$name requires a string value', current().span);
		return entry[0].substring(1, entry[0].length - 1);
	}

	function metadataStrings(values:Map<String, Array<String>>, name:String):Array<String> {
		var entry = values.get(name);
		if (entry == null)
			return [];
		if (entry.length == 0)
			fail('@$name requires at least one interface name', current().span);
		var result:Array<String> = [];
		for (value in entry) {
			if (!StringTools.startsWith(value, '"'))
				fail('@$name requires string values', current().span);
			var dependency = value.substring(1, value.length - 1);
			if (!isIdentifier(dependency))
				fail('@$name contains an invalid interface name "$dependency"', current().span);
			result.push(dependency);
		}
		return result;
	}

	function metadataInteger(values:Map<String, Array<String>>, name:String, required:Bool):Null<Int> {
		var entry = values.get(name);
		if (entry == null) {
			if (required)
				fail('@$name requires one integer value', current().span);
			return null;
		}
		if (entry.length != 1 || StringTools.startsWith(entry[0], '"'))
			fail('@$name requires one integer value', current().span);
		return Std.parseInt(entry[0]);
	}

	function metadataPair(values:Map<String, Array<String>>, name:String):Null<Array<Int>> {
		var entry = values.get(name);
		if (entry == null)
			return null;
		if (entry.length != 2)
			fail('@$name requires two integer values', current().span);
		if (StringTools.startsWith(entry[0], '"') || StringTools.startsWith(entry[1], '"'))
			fail('@$name requires two integer values', current().span);
		return [Std.parseInt(entry[0]), Std.parseInt(entry[1])];
	}

	function metadataFlag(values:Map<String, Array<String>>, name:String):Bool {
		var entry = values.get(name);
		if (entry == null)
			return false;
		if (entry.length != 0)
			fail('@$name does not accept values', current().span);
		return true;
	}

	function identifier():String {
		var token = current();
		if (!isIdentifier(token.text))
			fail('Expected identifier, got "${token.text}"', token.span);
		advance();
		return token.text;
	}

	static function isIdentifier(value:String):Bool {
		if (value.length == 0 || !isIdentifierStart(value.charCodeAt(0)))
			return false;
		for (index in 1...value.length) {
			var code = value.charCodeAt(index);
			if (!isIdentifierStart(code) && !(code >= "0".code && code <= "9".code))
				return false;
		}
		return true;
	}

	static inline function isIdentifierStart(code:Int):Bool
		return (code >= "A".code && code <= "Z".code) || (code >= "a".code && code <= "z".code) || code == "_".code;

	function integer():String {
		var token = current();
		if (!isIntegerLiteral(token.text))
			fail('Expected integer, got "${token.text}"', token.span);
		advance();
		return token.text;
	}

	static function isIntegerLiteral(value:String):Bool {
		if (value.length == 0)
			return false;
		var index = value.charCodeAt(0) == "-".code ? 1 : 0;
		if (index == value.length)
			return false;
		while (index < value.length) {
			var code = value.charCodeAt(index);
			if (code < "0".code || code > "9".code)
				return false;
			index++;
		}
		return true;
	}

	static function isHexInteger(value:String):Bool {
		if (value.length < 3 || value.charCodeAt(0) != "0".code || (value.charCodeAt(1) != "x".code && value.charCodeAt(1) != "X".code))
			return false;
		for (index in 2...value.length) {
			var code = value.charCodeAt(index);
			if (!((code >= "0".code && code <= "9".code)
				|| (code >= "A".code && code <= "F".code)
				|| (code >= "a".code && code <= "f".code)))
				return false;
		}
		return true;
	}

	function checkString():Bool
		return StringTools.startsWith(current().text, '"');

	inline function match(text:String):Bool {
		if (!check(text))
			return false;
		advance();
		return true;
	}

	function expect(text:String):HxiToken {
		if (text == ">" && check(">>")) {
			var combined = advance();
			tokens.insert(position, {text: ">", span: combined.span});
			return {text: ">", span: combined.span};
		}
		if (!check(text))
			fail('Expected "$text", got "${current().text}"', current().span);
		return advance();
	}

	function check(text:String):Bool
		return !atEnd() && current().text == text;

	function advance():HxiToken
		return tokens[position++];

	function current():HxiToken
		return position < tokens.length ? tokens[position] : {text: "<eof>", span: source.span(source.bytes.length, source.bytes.length)};

	function previous():HxiToken
		return tokens[position - 1];

	function atEnd():Bool
		return position >= tokens.length;

	static function fail(message:String, span:SourceSpan):Dynamic
		throw new CompileError(new Diagnostic("E3001", message, span));

	static function tokenize(source:SourceFile):HxiLexResult {
		var result:Array<HxiToken> = [], comments:Array<DocumentationComment> = [], bytes = source.bytes, position = 0;
		while (position < bytes.length) {
			var code = bytes.get(position);
			if (code == " ".code || code == "\t".code || code == "\n".code || code == "\r".code) {
				position++;
				continue;
			}
			if (code == "/".code && position + 1 < bytes.length && bytes.get(position + 1) == "/".code) {
				position += 2;
				while (position < bytes.length && bytes.get(position) != "\n".code)
					position++;
				continue;
			}
			if (code == "/".code && position + 1 < bytes.length && bytes.get(position + 1) == "*".code) {
				var commentStart = position;
				position += 2;
				while (position + 1 < bytes.length && !(bytes.get(position) == "*".code && bytes.get(position + 1) == "/".code))
					position++;
				if (position + 1 >= bytes.length)
					throw new CompileError(new Diagnostic("E3001", "Unterminated HXI block comment", source.span(commentStart, position)));
				if (commentStart + 2 < bytes.length && bytes.get(commentStart + 2) == "*".code && position >= commentStart + 3)
					comments.push({end: position + 2, documentation: DocumentationTools.normalize(source.slice(commentStart + 3, position))});
				position += 2;
				continue;
			}
			var start = position;
			if (code == "\"".code) {
				position++;
				while (position < bytes.length && bytes.get(position) != "\"".code)
					position += bytes.get(position) == "\\".code && position + 1 < bytes.length ? 2 : 1;
				if (position >= bytes.length)
					throw new CompileError(new Diagnostic("E3001", "Unterminated HXI string", source.span(start, position)));
				position++;
			} else if ((code >= "A".code && code <= "Z".code) || (code >= "a".code && code <= "z".code) || code == "_".code) {
				position++;
				while (position < bytes.length) {
					code = bytes.get(position);
					if (!((code >= "A".code && code <= "Z".code)
						|| (code >= "a".code && code <= "z".code)
						|| (code >= "0".code && code <= "9".code)
						|| code == "_".code))
						break;
					position++;
				}
			} else if ((code >= "0".code && code <= "9".code)
				|| (code == "-".code && position + 1 < bytes.length && bytes.get(position + 1) >= "0".code && bytes.get(position + 1) <= "9".code)) {
				position++;
				if (code == "0".code && position < bytes.length && (bytes.get(position) == "x".code || bytes.get(position) == "X".code)) {
					position++;
					while (position < bytes.length
						&& ((bytes.get(position) >= "0".code && bytes.get(position) <= "9".code)
							|| (bytes.get(position) >= "A".code && bytes.get(position) <= "F".code)
							|| (bytes.get(position) >= "a".code && bytes.get(position) <= "f".code)))
						position++;
				} else
					while (position < bytes.length && bytes.get(position) >= "0".code && bytes.get(position) <= "9".code)
						position++;
			} else if (code == "-".code && position + 1 < bytes.length && bytes.get(position + 1) == ">".code)
				position += 2;
			else if ((code == "<".code || code == ">".code) && position + 1 < bytes.length && bytes.get(position + 1) == code)
				position += 2;
			else if (isPunctuation(code))
				position++;
			else
				throw new CompileError(new Diagnostic("E3001", 'Unexpected HXI character "${String.fromCharCode(code)}"', source.span(start, start + 1)));
			result.push({text: source.slice(start, position), span: source.span(start, position)});
		}
		return {tokens: result, comments: comments};
	}

	static inline function isPunctuation(code:Int):Bool
		return code == "{".code || code == "}".code || code == "(".code || code == ")".code || code == "<".code || code == ">".code || code == ":".code
			|| code == ",".code || code == ";".code || code == "=".code || code == "@".code || code == "|".code || code == "-".code;
}
