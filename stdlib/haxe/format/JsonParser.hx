/* Derived from the Haxe standard library JsonParser under the MIT license. */
package haxe.format;

@:hlNative("haxeon_runtime", "__reflect_dynamic_object")
extern function jsonDynamicObject():Dynamic;

class JsonParser {
	public static function parse(text:String):Dynamic
		return new JsonParser(text).parseDocument();

	final text:String;
	var position:Int = 0;

	function new(text:String) {
		this.text = text;
	}

	function parseDocument():Dynamic {
		var result = parseValue();
		skipWhitespace();
		if (position != text.length) invalid("trailing data");
		return result;
	}

	function parseValue():Dynamic {
		skipWhitespace();
		if (position >= text.length) invalid("unexpected end of input");
		var code = text.charCodeAt(position);
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
			if (position >= text.length || text.charCodeAt(position) != 34) invalid("expected object field");
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
		while (position < text.length) {
			var code = text.charCodeAt(position++);
			if (code == 34) {
				output.addSub(text, start, position - start - 1);
				return output.toString();
			}
			if (code < 32) invalid("control character in string");
			if (code != 92) continue;
			output.addSub(text, start, position - start - 1);
			if (position >= text.length) invalid("unfinished escape");
			var escaped = text.charCodeAt(position++);
			switch escaped {
				case 34, 47, 92: output.addChar(escaped);
				case 98: output.addChar(8);
				case 102: output.addChar(12);
				case 110: output.addChar(10);
				case 114: output.addChar(13);
				case 116: output.addChar(9);
				case 117:
					var high = hex4();
					output.addChar(high);
					if (high >= 0xd800 && high <= 0xdbff) {
						if (position + 2 > text.length || text.charCodeAt(position) != 92 || text.charCodeAt(position + 1) != 117)
							invalid("unpaired high surrogate");
						position += 2;
						var low = hex4();
						if (low < 0xdc00 || low > 0xdfff) invalid("invalid low surrogate");
						output.addChar(low);
					} else if (high >= 0xdc00 && high <= 0xdfff) invalid("unpaired low surrogate");
				default: invalid("invalid escape");
			}
			start = position;
		}
		invalid("unclosed string");
	}

	function parseNumber():Dynamic {
		var start = position;
		if (take(45) && position >= text.length) invalid("unfinished number");
		if (take(48)) {
			if (position < text.length && digit(text.charCodeAt(position))) invalid("leading zero");
		} else {
			if (position >= text.length || !digit(text.charCodeAt(position))) invalid("expected digit");
			while (position < text.length && digit(text.charCodeAt(position))) position++;
		}
		var floating = false;
		if (take(46)) {
			floating = true;
			if (position >= text.length || !digit(text.charCodeAt(position))) invalid("expected fraction digit");
			while (position < text.length && digit(text.charCodeAt(position))) position++;
		}
		if (position < text.length && (text.charCodeAt(position) == 101 || text.charCodeAt(position) == 69)) {
			floating = true;
			position++;
			if (position < text.length && (text.charCodeAt(position) == 43 || text.charCodeAt(position) == 45)) position++;
			if (position >= text.length || !digit(text.charCodeAt(position))) invalid("expected exponent digit");
			while (position < text.length && digit(text.charCodeAt(position))) position++;
		}
		var token = text.substring(start, position);
		return floating ? Std.parseFloat(token) : Std.parseInt(token);
	}

	function literal(name:String, value:Dynamic):Dynamic {
		if (text.substring(position, position + name.length) != name) invalid("invalid literal");
		position += name.length;
		return value;
	}

	function hex4():Int {
		if (position + 4 > text.length) invalid("unfinished Unicode escape");
		var value = 0;
		for (_ in 0...4) {
			var code = text.charCodeAt(position++), digit = code >= 48 && code <= 57 ? code - 48
				: code >= 65 && code <= 70 ? code - 55 : code >= 97 && code <= 102 ? code - 87 : -1;
			if (digit < 0) invalid("invalid Unicode escape");
			value = value * 16 + digit;
		}
		return value;
	}

	function skipWhitespace():Void
		while (position < text.length && whitespace(text.charCodeAt(position))) position++;

	function take(code:Int):Bool {
		if (position >= text.length || text.charCodeAt(position) != code) return false;
		position++;
		return true;
	}

	function invalid(message:String):Void
		throw '$message at position $position';

	static function digit(code:Int):Bool return code >= 48 && code <= 57;
	static function whitespace(code:Int):Bool return code == 32 || code == 9 || code == 10 || code == 13;
}
