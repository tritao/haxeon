package compiler.syntax;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;

typedef ConditionalSource = {
	final text:String;
	final defines:Array<String>;
}

private typedef ConditionalFrame = {
	final parentActive:Bool;
	var active:Bool;
	var matched:Bool;
	var sawElse:Bool;
}

/** Source-offset-preserving evaluation of Haxe conditional directives. */
class ConditionalCompilation {
	public static function process(file:SourceFile, defines:Map<String, String>):ConditionalSource {
		if (file.text.indexOf("#") < 0)
			return {text: file.text, defines: []};
		var source = file.bytes, output = new StringBuf(), referenced:Map<String, Bool> = [], frames:Array<ConditionalFrame> = [], cursor = 0, scan = 0,
			quote = 0, escaped = false, lineComment = false, blockComment = false;
		while (scan < source.length) {
			var code = source.get(scan),
				next = scan + 1 < source.length ? source.get(scan + 1) : -1;
			if (lineComment) {
				if (code == "\n".code)
					lineComment = false;
				scan++;
				continue;
			}
			if (blockComment) {
				if (code == "*".code && next == "/".code) {
					blockComment = false;
					scan += 2;
				} else
					scan++;
				continue;
			}
			if (quote != 0) {
				if (escaped)
					escaped = false;
				else if (code == "\\".code)
					escaped = true;
				else if (code == quote)
					quote = 0;
				scan++;
				continue;
			}
			if (code == "/".code && next == "/".code) {
				lineComment = true;
				scan += 2;
				continue;
			}
			if (code == "/".code && next == "*".code) {
				blockComment = true;
				scan += 2;
				continue;
			}
			if (code == "\"".code || code == "'".code) {
				quote = code;
				scan++;
				continue;
			}
			if (code != "#".code) {
				scan++;
				continue;
			}
			var nameStart = scan + 1, nameEnd = nameStart;
			while (nameEnd < source.length && isDirectiveLetter(source.get(nameEnd)))
				nameEnd++;
			var name = file.slice(nameStart, nameEnd);
			if (name != "if" && name != "elseif" && name != "else" && name != "end" && name != "error") {
				if (isLineDirective(source, scan))
					fail(file, scan, 'Unknown conditional directive #$name');
				scan++;
				continue;
			}
			output.add(isActive(frames) ? file.slice(cursor, scan) : mask(source, cursor, scan));
			var directiveEnd = nameEnd;
			if (name == "if" || name == "elseif") {
				var lineEnd = findLineEnd(source, nameEnd),
					expression = file.slice(nameEnd, lineEnd),
					parser = new DefineExpression(expression, defines, referenced, file, nameEnd),
					condition = parser.parsePrefix();
				directiveEnd = nameEnd + haxe.io.Bytes.ofString(expression.substring(0, parser.consumed())).length;
				if (name == "if") {
					var parentActive = isActive(frames);
					frames.push({
						parentActive: parentActive,
						active: parentActive && condition,
						matched: condition,
						sawElse: false
					});
				} else {
					var frame = requireFrame(frames, file, scan, "#elseif");
					if (frame.sawElse)
						fail(file, scan, "#elseif after #else");
					frame.active = frame.parentActive && !frame.matched && condition;
					frame.matched = frame.matched || condition;
				}
			} else if (name == "else") {
				var frame = requireFrame(frames, file, scan, "#else");
				if (frame.sawElse)
					fail(file, scan, "Duplicate #else");
				frame.sawElse = true;
				frame.active = frame.parentActive && !frame.matched;
				frame.matched = true;
			} else if (name == "end") {
				requireFrame(frames, file, scan, "#end");
				frames.pop();
			} else {
				var lineEnd = findLineEnd(source, nameEnd);
				directiveEnd = lineEnd;
				if (isActive(frames)) {
					var message = StringTools.trim(file.slice(nameEnd, lineEnd));
					if (message.length >= 2
						&& (message.charAt(0) == "\""
							&& message.charAt(message.length - 1) == "\""
							|| message.charAt(0) == "'"
							&& message.charAt(message.length - 1) == "'"))
						message = message.substring(1, message.length - 1);
					fail(file, scan, message == "" ? "#error" : message);
				}
			}
			output.add(mask(source, scan, directiveEnd));
			cursor = directiveEnd;
			scan = directiveEnd;
		}
		output.add(isActive(frames) ? file.slice(cursor, source.length) : mask(source, cursor, source.length));
		if (frames.length > 0)
			fail(file, source.length, "Unclosed #if directive");
		var names = [for (name in referenced.keys()) name];
		names.sort(Reflect.compare);
		return {text: output.toString(), defines: names};
	}

	static function isDirectiveLetter(code:Int):Bool
		return code >= "a".code && code <= "z".code || code >= "A".code && code <= "Z".code;

	static function findLineEnd(source:haxe.io.Bytes, offset:Int):Int {
		while (offset < source.length && source.get(offset) != "\n".code)
			offset++;
		return offset;
	}

	static function isLineDirective(source:haxe.io.Bytes, offset:Int):Bool {
		var position = offset - 1;
		while (position >= 0 && source.get(position) != "\n".code) {
			var code = source.get(position);
			if (code != " ".code && code != "\t".code && code != "\r".code)
				return false;
			position--;
		}
		return true;
	}

	static function isActive(frames:Array<ConditionalFrame>):Bool
		return frames.length == 0 || frames[frames.length - 1].active;

	static function requireFrame(frames:Array<ConditionalFrame>, file:SourceFile, offset:Int, directive:String):ConditionalFrame {
		if (frames.length == 0)
			fail(file, offset, '$directive without #if');
		return frames[frames.length - 1];
	}

	static function mask(source:haxe.io.Bytes, start:Int, end:Int):String {
		var result = new StringBuf();
		for (index in start...end) {
			var code = source.get(index);
			result.addChar(code == "\n".code || code == "\r".code ? code : " ".code);
		}
		return result.toString();
	}

	static function fail(file:SourceFile, offset:Int, message:String):Dynamic
		throw new CompileError(new Diagnostic("E0002", message, file.span(offset, offset)));
}

private class DefineExpression {
	final expression:String;
	final defines:Map<String, String>;
	final referenced:Map<String, Bool>;
	final file:SourceFile;
	final baseOffset:Int;
	var position = 0;

	public function new(expression:String, defines:Map<String, String>, referenced:Map<String, Bool>, file:SourceFile, baseOffset:Int) {
		this.expression = expression;
		this.defines = defines;
		this.referenced = referenced;
		this.file = file;
		this.baseOffset = baseOffset;
	}

	public function parse():Bool {
		var result = parseOr();
		skipWhitespace();
		if (position != expression.length)
			fail("Unexpected conditional expression input");
		return result;
	}

	public function parsePrefix():Bool
		return parseOr();

	public function consumed():Int
		return position;

	function parseOr():Bool {
		var result = parseAnd();
		while (consume("||")) {
			var right = parseAnd();
			result = result || right;
		}
		return result;
	}

	function parseAnd():Bool {
		var result = parseUnary();
		while (consume("&&")) {
			var right = parseUnary();
			result = result && right;
		}
		return result;
	}

	function parseUnary():Bool {
		if (consume("!"))
			return !parseUnary();
		if (consume("(")) {
			var result = parseOr();
			if (!consume(")"))
				fail("Expected ) in conditional expression");
			return result;
		}
		var name = identifier();
		if (name.length == 0)
			fail("Expected define name");
		referenced.set(name, true);
		var value = defines.get(name);
		for (operation in ["==", "!=", ">=", "<=", ">", "<"])
			if (consume(operation))
				return compare(value, scalar(), operation);
		return value != null && value != "0" && value.toLowerCase() != "false";
	}

	function scalar():String {
		skipWhitespace();
		if (position >= expression.length)
			fail("Expected conditional comparison value");
		var quote = expression.charAt(position);
		if (quote == '"' || quote == "'") {
			position++;
			var start = position;
			while (position < expression.length && expression.charAt(position) != quote)
				position++;
			if (position >= expression.length)
				fail("Unclosed conditional string value");
			var result = expression.substring(start, position);
			position++;
			return result;
		}
		var value = identifier();
		if (value.length == 0)
			fail("Expected conditional comparison value");
		if (value == "version" && consume("(")) {
			var result = scalar();
			if (!consume(")"))
				fail("Expected ) after version value");
			return result;
		}
		var defined = defines.get(value);
		return defined == null ? value : defined;
	}

	static function compare(actual:Null<String>, expected:String, operation:String):Bool {
		if (actual == null)
			return operation == "!=";
		var order = versionOrder(actual, expected);
		if (order == null)
			order = Reflect.compare(actual, expected);
		return switch operation {
			case "==": order == 0;
			case "!=": order != 0;
			case ">=": order >= 0;
			case "<=": order <= 0;
			case ">": order > 0;
			case "<": order < 0;
			default: false;
		};
	}

	static function versionOrder(left:String, right:String):Null<Int> {
		var leftParts = versionParts(left), rightParts = versionParts(right);
		if (leftParts == null || rightParts == null)
			return null;
		var length = leftParts.length > rightParts.length ? leftParts.length : rightParts.length;
		for (index in 0...length) {
			var leftPart = index < leftParts.length ? leftParts[index] : 0,
				rightPart = index < rightParts.length ? rightParts[index] : 0;
			if (leftPart != rightPart)
				return leftPart < rightPart ? -1 : 1;
		}
		return 0;
	}

	static function versionParts(value:String):Null<Array<Int>> {
		if (value.length == 0)
			return null;
		var parts = value.split("."), result:Array<Int> = [];
		for (part in parts) {
			if (part.length == 0)
				return null;
			for (index in 0...part.length) {
				var code = part.charCodeAt(index);
				if (code < "0".code || code > "9".code)
					return null;
			}
			result.push(Std.parseInt(part));
		}
		return result;
	}

	function identifier():String {
		skipWhitespace();
		var start = position;
		while (position < expression.length) {
			var code = expression.charCodeAt(position);
			if (!(code >= "A".code && code <= "Z".code || code >= "a".code && code <= "z".code || code >= "0".code && code <= "9".code || code == "_".code
				|| code == ".".code))
				break;
			position++;
		}
		return expression.substring(start, position);
	}

	function consume(value:String):Bool {
		skipWhitespace();
		if (expression.substr(position, value.length) != value)
			return false;
		position += value.length;
		return true;
	}

	function skipWhitespace():Void
		while (position < expression.length && StringTools.isSpace(expression, position))
			position++;

	function fail(message:String):Dynamic {
		var offset = baseOffset + haxe.io.Bytes.ofString(expression.substring(0, position)).length;
		throw new CompileError(new Diagnostic("E0002", message, file.span(offset, offset)));
	}
}
