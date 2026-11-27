/* Derived from the Haxe standard library JsonParser under the MIT license. */
package haxe.format;

#if !wasm
@:hlNative("haxeon_runtime", "__reflect_dynamic_object")
internal extern function jsonDynamicObject():Dynamic;
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
		if (position != inputLength) throw invalid("trailing data");
		return result;
	}

	function parseValue():Dynamic {
		skipWhitespace();
		if (position >= inputLength) throw invalid("unexpected end of input");
		var code = codeAt(position);
		if (code == 34) return parseString();
		if (code == 123) return parseObject();
		if (code == 91) return parseArray();
		if (code == 116) return literal("true", true);
		if (code == 102) return literal("false", false);
		if (code == 110) return literal("null", null);
		if (code == 45 || code >= 48 && code <= 57) return parseNumber();
		throw invalid("unexpected character");
	}

	function parseObject():Dynamic {
		position++;
		var result:Dynamic = jsonDynamicObject();
		skipWhitespace();
		if (take(125)) return result;
		while (true) {
			skipWhitespace();
			if (position >= inputLength || codeAt(position) != 34) throw invalid("expected object field");
			var name:String = parseString();
			skipWhitespace();
			if (!take(58)) throw invalid("expected colon");
			Reflect.setField(result, name, parseValue());
			skipWhitespace();
			if (take(125)) return result;
			if (!take(44)) throw invalid("expected comma");
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
			if (!take(44)) throw invalid("expected comma");
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
			if (code < 32) throw invalid("control character in string");
			if (code != 92) continue;
			output.add(slice(start, position - start - 1));
			if (position >= inputLength) throw invalid("unfinished escape");
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
							throw invalid("unpaired high surrogate");
						position += 2;
						var low = hex4();
						if (low < 0xdc00 || low > 0xdfff) throw invalid("invalid low surrogate");
						output.addChar(0x10000 + ((high - 0xd800) << 10) + low - 0xdc00);
					} else if (high >= 0xdc00 && high <= 0xdfff) throw invalid("unpaired low surrogate");
					else output.addChar(high);
				default: throw invalid("invalid escape");
			}
			start = position;
		}
		throw invalid("unclosed string");
	}

	function parseNumber():Dynamic {
		var start = position;
		if (take(45) && position >= inputLength) throw invalid("unfinished number");
		if (take(48)) {
			if (position < inputLength && digit(codeAt(position))) throw invalid("leading zero");
		} else {
			if (position >= inputLength || !digit(codeAt(position))) throw invalid("expected digit");
			while (position < inputLength && digit(codeAt(position))) position++;
		}
		var floating = false;
		if (take(46)) {
			floating = true;
			if (position >= inputLength || !digit(codeAt(position))) throw invalid("expected fraction digit");
			while (position < inputLength && digit(codeAt(position))) position++;
		}
		if (position < inputLength && (codeAt(position) == 101 || codeAt(position) == 69)) {
			floating = true;
			position++;
			if (position < inputLength && (codeAt(position) == 43 || codeAt(position) == 45)) position++;
			if (position >= inputLength || !digit(codeAt(position))) throw invalid("expected exponent digit");
			while (position < inputLength && digit(codeAt(position))) position++;
		}
		var token = slice(start, position - start);
		return floating ? Std.parseFloat(token) : Std.parseInt(token);
	}

	function literal(name:String, value:Dynamic):Dynamic {
		if (slice(position, name.length) != name) throw invalid("invalid literal");
		position += name.length;
		return value;
	}

	function hex4():Int {
		if (position + 4 > inputLength) throw invalid("unfinished Unicode escape");
		var value = 0;
		for (_ in 0...4) {
			var code = codeAt(position++),
				digit = code >= 48 && code <= 57 ? code - 48
					: code >= 65 && code <= 70 ? code - 55 : code >= 97 && code <= 102 ? code - 87 : -1;
			if (digit < 0) throw invalid("invalid Unicode escape");
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

	/** The error for `message` at the current position, for the caller to throw. */
	function invalid(message:String):String
		return '$message at position $position';

	static function digit(code:Int):Bool return code >= 48 && code <= 57;
	static function whitespace(code:Int):Bool return code == 32 || code == 9 || code == 10 || code == 13;
}
