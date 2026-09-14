package compiler.ffi;

import haxe.Int64;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiLexer.HxiToken;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiEnumValue;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiDocumentation;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiParameterDirection;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiOwnership;
import compiler.documentation.Documentation.DocumentationComment;
import compiler.documentation.Documentation.DocumentationTools;

/** Builds a raw typed HXI model and reports syntax errors. */
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
		"bool32",
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
	final documentation:Map<String, HxiDocumentation> = [];
	final tokens:Array<HxiToken>;
	var position = 0;

	public static function parse(path:String, text:String):HxiInterface
		return new HxiParser(new SourceFile(path, text)).parseInterface();

	function new(source:SourceFile) {
		this.source = source;
		var lexed = HxiLexer.lex(source);
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
		var representation = parseType(),
			metadata = parseMetadata(["destroy"]),
			destroySymbol = metadataValue(metadata, "destroy", false),
			end = expect(";").span;
		return Handle(name, representation, destroySymbol, start.merge(end));
	}

	function parseCallback(start:SourceSpan):HxiDeclaration {
		advance();
		var name = identifier();
		expect("=");
		expect("fn");
		var parameters = parseParameters();
		expect("->");
		var result = parseType(),
			metadata = parseMetadata(["callconv"]),
			callConvention = metadataValue(metadata, "callconv", false);
		var end = expect(";").span;
		return Callback(name, parameters, result, callConvention == null ? "cdecl" : callConvention, start.merge(end));
	}

	function parseParameters():Array<HxiParameter> {
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
						"retained"), ownership = metadataOwnership(metadata,
						"owned"), bufferSize = metadataValue(metadata, "out_buffer",
						false), arrayCount = metadataValue(metadata, "in_array",
						false), outputArrayCount = metadataValue(metadata, "out_array",
						false), direction = out ? Out : inout ? InOut : bufferSize != null ? OutBuffer(bufferSize) : arrayCount != null ? InArray(arrayCount) : outputArrayCount != null ? OutArray(outputArrayCount) : In;
				parameters.push({
					name: name,
					type: type,
					direction: direction,
					ownership: ownership != Unspecified ? ownership : borrowed ? Borrowed : Unspecified,
					retained: retained,
					metadata: metadata,
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
				fieldMetadata = parseMetadata(["offset", "borrowed", "owned", "length_field", "struct_size"]),
				offset = metadataInteger(fieldMetadata, "offset", true),
				borrowed = metadataFlag(fieldMetadata, "borrowed"),
				ownership = metadataOwnership(fieldMetadata, "owned"),
				lengthField = metadataValue(fieldMetadata, "length_field", false),
				structSize = metadataFlag(fieldMetadata, "struct_size"),
				end = expect(";").span;
			var fieldSpan = fieldStart.merge(end);
			fields.push({
				name: fieldName,
				type: type,
				offset: offset,
				ownership: ownership != Unspecified ? ownership : borrowed ? Borrowed : Unspecified,
				lengthField: lengthField,
				structSize: structSize,
				metadata: fieldMetadata,
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
		var parameters = parseParameters();
		expect("->");
		var result = parseType(),
			metadata = parseMetadata(["symbol", "leaf", "borrowed", "owned", "length", "callconv"]),
			symbol = metadataValue(metadata, "symbol", false),
			leaf = metadataFlag(metadata, "leaf"),
			borrowed = metadataFlag(metadata, "borrowed"),
			ownership = metadataOwnership(metadata, "owned"),
			length = metadataValue(metadata, "length", false),
			callConvention = metadataValue(metadata, "callconv", false),
			end = expect(";").span;
		return Function(name, parameters, result, symbol, leaf, callConvention == null ? "cdecl" : callConvention, {
			ownership: ownership != Unspecified ? ownership : borrowed ? Borrowed : Unspecified,
			length: length,
			metadata: metadata
		}, start.merge(end));
	}

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
			return Array(element, length);
		}
		return primitives.indexOf(name) >= 0 ? Primitive(name) : Named(name);
	}

	static function declarationName(value:HxiDeclaration):{name:String, span:SourceSpan}
		return switch value {
			case Opaque(name, span) | Alias(name, _, span) | Handle(name, _, _, span) | Constant(name, _, span) | Structure(name, _, _, _, span) |
				Enumeration(name, _, _, _, span) | Callback(name, _, _, _, span) | Function(name, _, _, _, _, _, _, span):
				{name: name, span: span};
		};

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

	function metadataOwnership(values:Map<String, Array<String>>, name:String):HxiOwnership {
		var entry = values.get(name);
		if (entry == null)
			return Unspecified;
		if (entry.length == 0)
			return OwnedHandle;
		if (entry.length != 1 || !StringTools.startsWith(entry[0], '"'))
			fail('@$name accepts no value for a typed value handle or one string release symbol for an opaque pointer', current().span);
		return Owned(entry[0].substring(1, entry[0].length - 1));
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
}
