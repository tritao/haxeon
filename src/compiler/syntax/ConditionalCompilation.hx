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
		var source = file.text, output = new StringBuf(), referenced:Map<String, Bool> = [], frames:Array<ConditionalFrame> = [], offset = 0;
		while (offset < source.length) {
			var end = source.indexOf("\n", offset);
			if (end < 0)
				end = source.length;
			else
				end++;
			var line = source.substring(offset, end),
				trimmed = StringTools.ltrim(line),
				directive = StringTools.startsWith(trimmed, "#");
			if (directive) {
				var content = StringTools.trim(trimmed.substr(1)),
					separator = content.indexOf(" "),
					name = separator < 0 ? content : content.substr(0, separator),
					expression = separator < 0 ? "" : StringTools.trim(content.substr(separator + 1));
				switch name {
					case "if":
						var parentActive = isActive(frames),
							condition = new DefineExpression(expression, defines, referenced, file, offset).parse();
						frames.push({
							parentActive: parentActive,
							active: parentActive && condition,
							matched: condition,
							sawElse: false
						});
					case "elseif":
						var frame = requireFrame(frames, file, offset, "#elseif");
						if (frame.sawElse)
							fail(file, offset, "#elseif after #else");
						var condition = new DefineExpression(expression, defines, referenced, file, offset).parse();
						frame.active = frame.parentActive && !frame.matched && condition;
						frame.matched = frame.matched || condition;
					case "else":
						var frame = requireFrame(frames, file, offset, "#else");
						if (frame.sawElse)
							fail(file, offset, "Duplicate #else");
						frame.sawElse = true;
						frame.active = frame.parentActive && !frame.matched;
						frame.matched = true;
					case "end":
						requireFrame(frames, file, offset, "#end");
						frames.pop();
					default:
						fail(file, offset, 'Unknown conditional directive #$name');
				}
				output.add(mask(line));
			} else
				output.add(isActive(frames) ? line : mask(line));
			offset = end;
		}
		if (frames.length > 0)
			fail(file, source.length, "Unclosed #if directive");
		var names = [for (name in referenced.keys()) name];
		names.sort(Reflect.compare);
		return {text: output.toString(), defines: names};
	}

	static function isActive(frames:Array<ConditionalFrame>):Bool
		return frames.length == 0 || frames[frames.length - 1].active;

	static function requireFrame(frames:Array<ConditionalFrame>, file:SourceFile, offset:Int, directive:String):ConditionalFrame {
		if (frames.length == 0)
			fail(file, offset, '$directive without #if');
		return frames[frames.length - 1];
	}

	static function mask(value:String):String {
		var result = new StringBuf();
		for (index in 0...value.length) {
			var code = value.charCodeAt(index);
			result.addChar(code == 10 || code == 13 ? code : 32);
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
		var defined = defines.get(value);
		return defined == null ? value : defined;
	}

	static function compare(actual:Null<String>, expected:String, operation:String):Bool {
		if (actual == null)
			return operation == "!=";
		var leftNumber = Std.parseFloat(actual),
			rightNumber = Std.parseFloat(expected),
			numeric = !Math.isNaN(leftNumber) && !Math.isNaN(rightNumber),
			order = numeric ? (leftNumber < rightNumber ? -1 : leftNumber > rightNumber ? 1 : 0) : Reflect.compare(actual, expected);
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

	function identifier():String {
		skipWhitespace();
		var start = position;
		while (position < expression.length) {
			var code = expression.charCodeAt(position);
			if (!(code >= 65 && code <= 90 || code >= 97 && code <= 122 || code >= 48 && code <= 57 || code == 95 || code == 46))
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

	function fail(message:String):Dynamic
		throw new CompileError(new Diagnostic("E0002", message, file.span(baseOffset + position, baseOffset + position)));
}
