package compiler.ffi;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiEnumValue;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiPointerOwnership;
import compiler.ffi.HxiAbi.HxiAbiValue;

private typedef HxiToken = {
	final text:String;
	final span:SourceSpan;
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
	final tokens:Array<HxiToken>;
	var position = 0;

	public static function parse(path:String, text:String):HxiInterface
		return new HxiParser(new SourceFile(path, text)).parseInterface();

	function new(source:SourceFile) {
		this.source = source;
		tokens = tokenize(source);
	}

	function parseInterface():HxiInterface {
		var start = expect("interface").span,
			name = identifier(),
			metadata = parseMetadata(["target", "library"]);
		expect("{");
		var declarations = [];
		while (!check("}"))
			declarations.push(parseDeclaration());
		var end = expect("}").span;
		if (!atEnd())
			fail('Unexpected token "${current().text}"', current().span);
		var target = metadataValue(metadata, "target", true),
			library = metadataValue(metadata, "library", false),
			result = new HxiInterface(name, target, library, declarations, start.merge(end));
		validate(result);
		return result;
	}

	function parseDeclaration():HxiDeclaration {
		var start = current().span;
		return switch current().text {
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
			case "const":
				advance();
				var name = identifier();
				expect("=");
				var value = integer(), end = expect(";").span;
				Constant(name, value, start.merge(end));
			case "struct": parseStructure(start);
			case "enum": parseEnumeration(start, false);
			case "flags": parseEnumeration(start, true);
			case "extern": parseFunction(start);
			default: fail('Expected HXI declaration, got "${current().text}"', current().span);
		}
	}

	function parseEnumeration(start:SourceSpan, flags:Bool):HxiDeclaration {
		advance();
		var name = identifier();
		expect(":");
		var representation = parseType();
		expect("{");
		var values:Array<HxiEnumValue> = [];
		while (!check("}")) {
			var valueStart = current().span, valueName = identifier();
			expect("=");
			var value = parseEnumExpression(), end = expect(";").span;
			values.push({name: valueName, value: value, span: valueStart.merge(end)});
		}
		var end = expect("}").span;
		return Enumeration(name, representation, flags, values, start.merge(end));
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
		if (~/^0[xX][0-9A-Fa-f]+$/.match(token.text))
			value = parseHex(token.text);
		else if (~/^-?[0-9]+$/.match(token.text))
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
				digit = code >= 48 && code <= 57 ? code - 48 : code >= 65 && code <= 70 ? code - 55 : code - 87;
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
			fields.push({
				name: fieldName,
				type: type,
				offset: offset,
				ownership: owned != null ? Owned(owned) : borrowed ? Borrowed : Unspecified,
				lengthField: lengthField,
				span: fieldStart.merge(end)
			});
		}
		var end = expect("}").span;
		return Structure(name, layout[0], layout[1], fields, start.merge(end));
	}

	function parseFunction(start:SourceSpan):HxiDeclaration {
		expect("extern");
		expect("fn");
		var name = identifier();
		expect("(");
		var parameters:Array<HxiParameter> = [];
		if (!check(")"))
			do {
				var parameterStart = current().span,
					parameterName = identifier();
				expect(":");
				parameters.push({name: parameterName, type: parseType(), span: parameterStart.merge(previous().span)});
			} while (match(","));
		expect(")");
		expect("->");
		var result = parseType(),
			metadata = parseMetadata(["symbol", "leaf", "borrowed", "owned", "length"]),
			symbol = metadataValue(metadata, "symbol", false),
			leaf = metadataFlag(metadata, "leaf"),
			borrowed = metadataFlag(metadata, "borrowed"),
			owned = metadataValue(metadata, "owned", false),
			length = metadataValue(metadata, "length", false),
			end = expect(";").span;
		if (borrowed && owned != null)
			fail('Function "$name" cannot combine @borrowed and @owned', start);
		if ((borrowed || owned != null || length != null) && !pointerLike(result))
			fail('Pointer result metadata on "$name" requires a pointer return type', start);
		return Function(name, parameters, result, symbol, leaf, {
			ownership: owned != null ? Owned(owned) : borrowed ? Borrowed : Unspecified,
			length: length
		}, start.merge(end));
	}

	static function pointerLike(type:HxiType):Bool
		return switch type {
			case Pointer(_): true;
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

	function validate(value:HxiInterface):Void {
		var names:Map<String, SourceSpan> = [],
			declarationsByName:Map<String, HxiDeclaration> = [];
		for (declaration in value.declarations) {
			var named = declarationName(declaration);
			if (names.exists(named.name))
				fail('Duplicate HXI declaration "${named.name}"', named.span);
			names.set(named.name, named.span);
			declarationsByName.set(named.name, declaration);
		}
		validateAliasCycles(value.declarations);
		var abi = HxiAbi.forInterface(value);
		for (declaration in value.declarations)
			switch declaration {
				case Opaque(_, _) | Constant(_, _, _):
				case Alias(_, type, span):
					validateType(type, names, span, false);
				case Structure(name, size, align, fields, span):
					if (size < 0 || align <= 0 || (align & (align - 1)) != 0 || size % align != 0)
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
						validateType(field.type, names, field.span, false);
						switch field.ownership {
							case Owned(_): fail('Owned pointer field "${field.name}" is not supported; keep ownership in a separate handle', field.span);
							case Borrowed:
								if (!opaquePointerLike(field.type,
									declarationsByName)) fail('@borrowed field "${field.name}" requires a pointer to an opaque type', field.span);
							case Unspecified:
						}
						if (field.lengthField != null)
							fail('@length_field on "${field.name}" is reserved until structures can retain input buffers', field.span);
					}
				case Enumeration(name, representation, _, values, span):
					validateType(representation, names, span, false);
					var integer = switch abi.classify(representation) {
						case IntegerValue(bits, sign) if (bits <= 32): {bits: bits, signed: sign == Signed};
						case _: fail('Enum "$name" requires an 8/16/32-bit integer representation', span);
					};
					var valueNames:Map<String, Bool> = [],
						seenValues:Map<Int, String> = [];
					for (entry in values) {
						if (valueNames.exists(entry.name))
							fail('Duplicate value "${entry.name}" in enum "$name"', entry.span);
						valueNames.set(entry.name, true);
						if (integer.bits < 32) {
							var minimum = integer.signed ? -(1 << (integer.bits - 1)) : 0;
							var maximum = integer.signed ? (1 << (integer.bits - 1)) - 1 : (1 << integer.bits) - 1;
							if (entry.value < minimum || entry.value > maximum)
								fail('Value "${entry.name}" is outside the representation of enum "$name"', entry.span);
						}
						if (seenValues.exists(entry.value))
							fail('Value "${entry.name}" duplicates "${seenValues.get(entry.value)}" in enum "$name"', entry.span);
						seenValues.set(entry.value, entry.name);
					}
				case Function(name, parameters, result, _, _, resultPolicy, span):
					for (parameter in parameters)
						validateType(parameter.type, names, parameter.span, false);
					validateType(result, names, span, true);
					if (resultPolicy.length != null && !bytePointerLike(result, declarationsByName))
						fail('@length on "$name" requires a pointer to byte-sized data or void', span);
			}
	}

	static function typeLayout(type:HxiType, abi:HxiAbi, declarations:Map<String, HxiDeclaration>, resolving:Map<String, Bool>):Null<{
		size:Int,
		align:Int
	}>
		return switch type {
			case Const(element): typeLayout(element, abi, declarations, resolving);
			case Nullable(element): pointerLike(element) ? typeLayout(element, abi, declarations, resolving) : null;
			case Pointer(_): {size: Std.int(abi.pointerBits / 8), align: Std.int(abi.pointerBits / 8)};
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
						case Structure(_, size, align, _, _): {size: size, align: align};
						case _: null;
					};
					resolving.remove(name);
					result;
				}
		};

	function validateAliasCycles(declarations:Array<HxiDeclaration>):Void {
		var aliases:Map<String, {type:HxiType, span:SourceSpan}> = [];
		for (declaration in declarations)
			switch declaration {
				case Alias(name, type, span):
					aliases.set(name, {type: type, span: span});
				case _:
			}
		var visiting:Map<String, Bool> = [], complete:Map<String, Bool> = [];
		function visit(name:String):Void {
			if (complete.exists(name))
				return;
			if (visiting.exists(name))
				fail('Cyclic HXI type alias "$name"', aliases.get(name).span);
			var alias = aliases.get(name);
			if (alias == null)
				return;
			visiting.set(name, true);
			visitTypeAliases(alias.type, aliases, visit);
			visiting.remove(name);
			complete.set(name, true);
		}

		for (name in aliases.keys())
			visit(name);
	}

	static function bytePointerLike(type:HxiType, names:Map<String, HxiDeclaration>):Bool
		return switch type {
			case Nullable(element) | Const(element): bytePointerLike(element, names);
			case Pointer(element): byteElement(element, names);
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

	static function visitTypeAliases(type:HxiType, aliases:Map<String, {type:HxiType, span:SourceSpan}>, visit:String->Void):Void
		switch type {
			case Named(name) if (aliases.exists(name)):
				visit(name);
			case Pointer(element) | Nullable(element) | Const(element) | Array(element, _):
				visitTypeAliases(element, aliases, visit);
			case _:
		}

	function validateType(type:HxiType, names:Map<String, SourceSpan>, span:SourceSpan, allowVoid:Bool):Void
		switch type {
			case Primitive("void") if (!allowVoid):
				fail("Void is not valid in this ABI position", span);
			case Primitive(_):
			case Named(name) if (!names.exists(name)):
				fail('Unknown HXI type "$name"', span);
			case Named(_):
			case Pointer(element):
				validateType(element, names, span, true);
			case Nullable(element):
				switch element {
					case Pointer(_):
					default: fail("nullable<> requires a pointer type", span);
				}
				validateType(element, names, span, false);
			case Const(element):
				validateType(element, names, span, allowVoid);
			case Array(element, _):
				validateType(element, names, span, false);
		}

	static function declarationName(value:HxiDeclaration):{name:String, span:SourceSpan}
		return switch value {
			case Opaque(name, span) | Alias(name, _, span) | Constant(name, _, span) | Structure(name, _, _, _, span) | Enumeration(name, _, _, _, span) |
				Function(name, _, _, _, _, _, span):
				{name: name, span: span};
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
						if (!checkString() && !~/^-?[0-9]+$/.match(current().text))
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
		if (!~/^[A-Za-z_][A-Za-z0-9_]*$/.match(token.text))
			fail('Expected identifier, got "${token.text}"', token.span);
		advance();
		return token.text;
	}

	function integer():String {
		var token = current();
		if (!~/^-?[0-9]+$/.match(token.text))
			fail('Expected integer, got "${token.text}"', token.span);
		advance();
		return token.text;
	}

	function checkString():Bool
		return StringTools.startsWith(current().text, '"');

	function match(text:String):Bool {
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

	function fail(message:String, span:SourceSpan):Dynamic
		throw new CompileError(new Diagnostic("E3001", message, span));

	static function tokenize(source:SourceFile):Array<HxiToken> {
		var result = [], bytes = source.bytes, position = 0;
		while (position < bytes.length) {
			var code = bytes.get(position);
			if (code == 32 || code == 9 || code == 10 || code == 13) {
				position++;
				continue;
			}
			if (code == 47 && position + 1 < bytes.length && bytes.get(position + 1) == 47) {
				position += 2;
				while (position < bytes.length && bytes.get(position) != 10)
					position++;
				continue;
			}
			var start = position;
			if (code == 34) {
				position++;
				while (position < bytes.length && bytes.get(position) != 34)
					position += bytes.get(position) == 92 && position + 1 < bytes.length ? 2 : 1;
				if (position >= bytes.length)
					throw new CompileError(new Diagnostic("E3001", "Unterminated HXI string", source.span(start, position)));
				position++;
			} else if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95) {
				position++;
				while (position < bytes.length) {
					code = bytes.get(position);
					if (!((code >= 65 && code <= 90) || (code >= 97 && code <= 122) || (code >= 48 && code <= 57) || code == 95))
						break;
					position++;
				}
			} else if ((code >= 48 && code <= 57)
				|| (code == 45 && position + 1 < bytes.length && bytes.get(position + 1) >= 48 && bytes.get(position + 1) <= 57)) {
				position++;
				if (code == 48 && position < bytes.length && (bytes.get(position) == 120 || bytes.get(position) == 88)) {
					position++;
					while (position < bytes.length
						&& ((bytes.get(position) >= 48 && bytes.get(position) <= 57)
							|| (bytes.get(position) >= 65 && bytes.get(position) <= 70)
							|| (bytes.get(position) >= 97 && bytes.get(position) <= 102)))
						position++;
				} else
					while (position < bytes.length && bytes.get(position) >= 48 && bytes.get(position) <= 57)
						position++;
			} else if (code == 45 && position + 1 < bytes.length && bytes.get(position + 1) == 62)
				position += 2;
			else if ((code == 60 || code == 62) && position + 1 < bytes.length && bytes.get(position + 1) == code)
				position += 2;
			else if ("{}()<>:,;=@|-".indexOf(String.fromCharCode(code)) >= 0)
				position++;
			else
				throw new CompileError(new Diagnostic("E3001", 'Unexpected HXI character "${String.fromCharCode(code)}"', source.span(start, start + 1)));
			result.push({text: source.slice(start, position), span: source.span(start, position)});
		}
		return result;
	}
}
