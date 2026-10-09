/* Derived from the Haxe standard library JsonParser under the MIT license. */
package haxe.format;

#if !wasm
@:hlNative("haxeon_runtime", "__reflect_dynamic_object")
extern function jsonDynamicObject():Dynamic;
#else
function jsonDynamicObject():Dynamic
	return new runtime.DynamicObject();
#end

class JsonParser {
	public static function parse(text:String):Dynamic
		return new JsonParser(text).parseDocument();

	final text:String;
	#if wasm
	// Wasm strings are UTF-8: charCodeAt walks from the beginning to find a character.
	// Scan bytes once instead; JSON structural characters are all ASCII.
	final bytes:haxe.io.Bytes;
	#end
	final inputLength:Int;
	var position:Int = 0;

	function new(text:String) {
		this.text = text;
		#if wasm
		bytes = haxe.io.Bytes.ofString(text);
		inputLength = bytes.length;
		#else
		inputLength = text.length;
		#end
	}

	inline function codeAt(offset:Int):Int {
		#if wasm
		return bytes.get(offset);
		#else
		return text.charCodeAt(offset);
		#end
	}

	inline function slice(offset:Int, length:Int):String {
		#if wasm
		return bytes.getString(offset, length);
		#else
		return text.substr(offset, length);
		#end
	}

	function parseDocument():Dynamic {
		var result = parseValue();
		skipWhitespace();
		if (position != inputLength) invalid("trailing data");
		return result;
	}

	function parseValue():Dynamic {
		skipWhitespace();
		if (position >= inputLength) invalid("unexpected end of input");
		var code = codeAt(position);
		if (code == 34) return parseString();
		if (code == 123) return parseObject();
		if (code == 91) return parseArray();
		if (code == 116) return literal("true", true);
		if (code == 102) return literal("false", false);
		if (code == 110) return literal("null", null);
		if (code == 45 || code >= 48 && code <= 57) return parseNumber();
		invalid("unexpected character");
	}

	function parseObject():Dynamic {
		position++;
		var result:Dynamic = jsonDynamicObject();
		skipWhitespace();
		if (take(125)) return result;
		while (true) {
			skipWhitespace();
			if (position >= inputLength || codeAt(position) != 34) invalid("expected object field");
			var name:String = parseString();
			skipWhitespace();
			if (!take(58)) invalid("expected colon");
			Reflect.setField(result, name, parseValue());
			skipWhitespace();
			if (take(125)) return result;
			if (!take(44)) invalid("expected comma");
		}
	}

	function parseArray():Array<Dynamic> {
		position++;
		var result:Array<Dynamic> = [];
		skipWhitespace();
		if (take(93)) return result;
		while (true) {
			result.push(parseValue());
			skipWhitespace();
			if (take(93)) return result;
			if (!take(44)) invalid("expected comma");
		}
	}

	function parseString():String {
		position++;
		var output = new StringBuf(), start = position;
		while (position < inputLength) {
			var code = codeAt(position++);
			if (code == 34) {
				output.add(slice(start, position - start - 1));
				return output.toString();
			}
			if (code < 32) invalid("control character in string");
			if (code != 92) continue;
			output.add(slice(start, position - start - 1));
			if (position >= inputLength) invalid("unfinished escape");
			var escaped = codeAt(position++);
			switch escaped {
				case 34, 47, 92: output.addChar(escaped);
				case 98: output.addChar(8);
				case 102: output.addChar(12);
				case 110: output.addChar(10);
				case 114: output.addChar(13);
				case 116: output.addChar(9);
				case 117:
					var high = hex4();
					if (high >= 0xd800 && high <= 0xdbff) {
						if (position + 2 > inputLength || codeAt(position) != 92 || codeAt(position + 1) != 117)
							invalid("unpaired high surrogate");
						position += 2;
						var low = hex4();
						if (low < 0xdc00 || low > 0xdfff) invalid("invalid low surrogate");
						addUnicode(output, 0x10000 + ((high - 0xd800) << 10) + low - 0xdc00);
					} else if (high >= 0xdc00 && high <= 0xdfff) invalid("unpaired low surrogate");
					else addUnicode(output, high);
				default: invalid("invalid escape");
			}
			start = position;
		}
		invalid("unclosed string");
	}

	static function addUnicode(output:StringBuf, code:Int):Void {
		#if wasm
		// String.fromCharCode currently constructs one byte on Wasm. Encode JSON escapes as UTF-8.
		var length = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
		var encoded = haxe.io.Bytes.alloc(length);
		if (length == 1) encoded.set(0, code);
		else {
			for (index in 1...length) encoded.set(index, 0x80 | ((code >>> ((length - index - 1) * 6)) & 63));
			encoded.set(0, (length == 2 ? 0xc0 : length == 3 ? 0xe0 : 0xf0) | (code >>> ((length - 1) * 6)));
		}
		output.add(encoded.getString(0, length));
		#else
		if (code <= 0xffff) output.addChar(code);
		else {
			output.addChar(0xd800 + ((code - 0x10000) >>> 10));
			output.addChar(0xdc00 + ((code - 0x10000) & 1023));
		}
		#end
	}

	function parseNumber():Dynamic {
		var start = position;
		if (take(45) && position >= inputLength) invalid("unfinished number");
		if (take(48)) {
			if (position < inputLength && digit(codeAt(position))) invalid("leading zero");
		} else {
			if (position >= inputLength || !digit(codeAt(position))) invalid("expected digit");
			while (position < inputLength && digit(codeAt(position))) position++;
		}
		var floating = false;
		if (take(46)) {
			floating = true;
			if (position >= inputLength || !digit(codeAt(position))) invalid("expected fraction digit");
			while (position < inputLength && digit(codeAt(position))) position++;
		}
		if (position < inputLength && (codeAt(position) == 101 || codeAt(position) == 69)) {
			floating = true;
			position++;
			if (position < inputLength && (codeAt(position) == 43 || codeAt(position) == 45)) position++;
			if (position >= inputLength || !digit(codeAt(position))) invalid("expected exponent digit");
			while (position < inputLength && digit(codeAt(position))) position++;
		}
		var token = slice(start, position - start);
		return floating ? Std.parseFloat(token) : Std.parseInt(token);
	}

	function literal(name:String, value:Dynamic):Dynamic {
		if (slice(position, name.length) != name) invalid("invalid literal");
		position += name.length;
		return value;
	}

	function hex4():Int {
		if (position + 4 > inputLength) invalid("unfinished Unicode escape");
		var value = 0;
		for (_ in 0...4) {
			var code = codeAt(position++), digit = code >= 48 && code <= 57 ? code - 48
				: code >= 65 && code <= 70 ? code - 55 : code >= 97 && code <= 102 ? code - 87 : -1;
			if (digit < 0) invalid("invalid Unicode escape");
			value = value * 16 + digit;
		}
		return value;
	}

	function skipWhitespace():Void
		while (position < inputLength && whitespace(codeAt(position))) position++;

	function take(code:Int):Bool {
		if (position >= inputLength || codeAt(position) != code) return false;
		position++;
		return true;
	}

	function invalid(message:String):Void
		throw '$message at position $position';

	static function digit(code:Int):Bool return code >= 48 && code <= 57;
	static function whitespace(code:Int):Bool return code == 32 || code == 9 || code == 10 || code == 13;
}
