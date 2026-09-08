private typedef ERegMatch = {
	final pos:Int;
	final len:Int;
}

@:hlNative("realtime_runtime", "__regexp_new")
extern function regexpNew(pattern:String, options:String):hl.Abstract<"ereg">;

@:hlNative("realtime_runtime", "__regexp_match")
extern function regexpMatch(expression:hl.Abstract<"ereg">, value:String, position:Int, length:Int):Bool;

@:hlNative("realtime_runtime", "__regexp_matched_pos")
extern function regexpMatchedPos(expression:hl.Abstract<"ereg">, group:Int):Int;

@:hlNative("realtime_runtime", "__regexp_matched_length")
extern function regexpMatchedLength(expression:hl.Abstract<"ereg">, group:Int):Int;

@:hlNative("realtime_runtime", "__regexp_matched_num")
extern function regexpMatchedNum(expression:hl.Abstract<"ereg">):Int;

/** PCRE2-backed regular expressions with Haxe-compatible global iteration. */
class EReg {
	final expression:hl.Abstract<"ereg">;
	final global:Bool;
	var last:String = "";
	var hasMatch:Bool = false;

	public function new(pattern:String, options:String) {
		global = options.indexOf("g") >= 0;
		var nativeOptions = "";
		for (index in 0...options.length) {
			var option = options.charAt(index);
			if (option != "g") {
				if ("ismu".indexOf(option) < 0) throw 'Unsupported regular-expression option "$option"';
				nativeOptions += option;
			}
		}
		expression = regexpNew(pattern, nativeOptions);
	}

	public function match(value:String):Bool
		return matchSub(value, 0);

	public function matchSub(value:String, position:Int, length:Int = -1):Bool {
		if (position < 0 || position > value.length) {
			hasMatch = false;
			return false;
		}
		var available = value.length - position;
		if (length < 0 || length > available) length = available;
		hasMatch = regexpMatch(expression, value, position, length);
		last = hasMatch ? value : "";
		return hasMatch;
	}

	public function matched(group:Int):String {
		requireMatch();
		var position = regexpMatchedPos(expression, group), length = regexpMatchedLength(expression, group);
		return position < 0 || length < 0 ? "" : last.substr(position, length);
	}

	public function matchedLeft():String {
		requireMatch();
		return last.substr(0, regexpMatchedPos(expression, 0));
	}

	public function matchedRight():String {
		requireMatch();
		var position = regexpMatchedPos(expression, 0), length = regexpMatchedLength(expression, 0);
		return last.substr(position + length);
	}

	public function matchedPos():ERegMatch {
		requireMatch();
		return {pos: regexpMatchedPos(expression, 0), len: regexpMatchedLength(expression, 0)};
	}

	public function matchedNum():Int {
		requireMatch();
		return regexpMatchedNum(expression);
	}

	public function replace(value:String, replacement:String):String {
		var output = new StringBuf(), offset = 0;
		while (offset <= value.length && matchSub(value, offset)) {
			var position = regexpMatchedPos(expression, 0), length = regexpMatchedLength(expression, 0);
			output.add(value.substring(offset, position));
			output.add(expandReplacement(replacement));
			var next = position + length;
			if (!global) {
				offset = next;
				break;
			}
			if (length == 0 && next == offset) {
				if (next >= value.length) {
					offset = value.length;
					break;
				}
				var advanced = nextScalarOffset(value, next);
				output.add(value.substring(next, advanced));
				next = advanced;
			}
			offset = next;
		}
		output.add(value.substring(offset));
		return output.toString();
	}

	public function split(value:String):Array<String> {
		var result:Array<String> = [], offset = 0;
		while (offset <= value.length && matchSub(value, offset)) {
			var position = regexpMatchedPos(expression, 0), length = regexpMatchedLength(expression, 0);
			result.push(value.substring(offset, position));
			var next = position + length;
			if (!global) {
				offset = next;
				break;
			}
			if (length == 0 && next == offset) {
				if (next >= value.length) break;
				next = nextScalarOffset(value, next);
			}
			offset = next;
		}
		result.push(value.substring(offset));
		return result;
	}

	function expandReplacement(replacement:String):String {
		var output = new StringBuf(), index = 0;
		while (index < replacement.length) {
			if (replacement.charAt(index) != "$" || index + 1 >= replacement.length) {
				output.add(replacement.charAt(index++));
				continue;
			}
			var code = replacement.charCodeAt(index + 1);
			if (code == 36) {
				output.add("$");
				index += 2;
			} else if (code >= 49 && code <= 57) {
				var group = code - 48;
				if (group < regexpMatchedNum(expression)) output.add(matched(group)); else output.add("$" + replacement.charAt(index + 1));
				index += 2;
			} else
				output.add(replacement.charAt(index++));
		}
		return output.toString();
	}

	function requireMatch():Void {
		if (!hasMatch) throw "No regular-expression match is available";
	}

	static function nextScalarOffset(value:String, offset:Int):Int {
		if (offset >= value.length) return value.length;
		var first = value.charCodeAt(offset);
		return first >= 0xD800 && first <= 0xDBFF && offset + 1 < value.length
			&& value.charCodeAt(offset + 1) >= 0xDC00 && value.charCodeAt(offset + 1) <= 0xDFFF ? offset + 2 : offset + 1;
	}

	public static function escape(value:String):String {
		var output = new StringBuf();
		for (index in 0...value.length) {
			var character = value.charAt(index);
			if ("\\^$.*+?()[]{}|".indexOf(character) >= 0) output.add("\\");
			output.add(character);
		}
		return output.toString();
	}
}
