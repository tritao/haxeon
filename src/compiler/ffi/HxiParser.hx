package compiler.ffi;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiPointerOwnership;

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
			case "extern": parseFunction(start);
			default: fail('Expected HXI declaration, got "${current().text}"', current().span);
		}
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
				fieldMetadata = parseMetadata(["offset"]),
				offset = metadataInteger(fieldMetadata, "offset", true),
				end = expect(";").span;
			fields.push({
				name: fieldName,
				type: type,
				offset: offset,
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
		var names:Map<String, SourceSpan> = [];
		for (declaration in value.declarations) {
			var named = declarationName(declaration);
			if (names.exists(named.name))
				fail('Duplicate HXI declaration "${named.name}"', named.span);
			names.set(named.name, named.span);
		}
		validateAliasCycles(value.declarations);
		for (declaration in value.declarations)
			switch declaration {
				case Opaque(_, _) | Constant(_, _, _):
				case Alias(_, type, span):
					validateType(type, names, span, false);
				case Structure(name, size, align, fields, span):
					if (size < 0 || align <= 0 || (align & (align - 1)) != 0)
						fail('Struct "$name" has invalid layout', span);
					var fieldNames:Map<String, Bool> = [];
					for (field in fields) {
						if (fieldNames.exists(field.name))
							fail('Duplicate field "${field.name}" in struct "$name"', field.span);
						fieldNames.set(field.name, true);
						if (field.offset == null || field.offset < 0 || field.offset >= size)
							fail('Field "${field.name}" has an invalid offset for struct "$name"', field.span);
						validateType(field.type, names, field.span, false);
					}
				case Function(_, parameters, result, _, _, _, span):
					for (parameter in parameters)
						validateType(parameter.type, names, parameter.span, false);
					validateType(result, names, span, true);
			}
	}

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
			case Opaque(name, span) | Alias(name, _, span) | Constant(name, _, span) | Structure(name, _, _, _, span) | Function(name, _, _, _, _, _, span):
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
				while (position < bytes.length && bytes.get(position) >= 48 && bytes.get(position) <= 57)
					position++;
			} else if (code == 45 && position + 1 < bytes.length && bytes.get(position + 1) == 62)
				position += 2;
			else if ("{}()<>:,;=@".indexOf(String.fromCharCode(code)) >= 0)
				position++;
			else
				throw new CompileError(new Diagnostic("E3001", 'Unexpected HXI character "${String.fromCharCode(code)}"', source.span(start, start + 1)));
			result.push({text: source.slice(start, position), span: source.span(start, position)});
		}
		return result;
	}
}
