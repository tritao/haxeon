package compiler.service;

import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.ConditionalCompilation;

/** Conservative syntax-aware whitespace formatting that preserves source trivia. */
class SourceFormatter {
	public static function format(source:String, tabSize:Int, insertSpaces:Bool, ?rangeStart:Int, ?rangeEnd:Int):Null<String> {
		try {
			var file = new SourceFile("<format>", source),
				conditional = ConditionalCompilation.process(file, []);
			new Parser(new Lexer(file, conditional.text).tokenize()).parseProgram();
		} catch (_:CompileError)
			return null
		catch (_:Dynamic)
			return null;
		var newline = source.indexOf("\r\n") >= 0 ? "\r\n" : "\n", normalized = StringTools.replace(source, "\r\n", "\n"), lines = normalized.split("\n"),
			trailingNewline = StringTools.endsWith(normalized, "\n"), output:Array<String> = [], lineStarts = [0], depth = 0, blockComment = false,
			quote = -1, escaped = false, start = rangeStart == null ? 0 : rangeStart, end = rangeEnd == null ? source.length : rangeEnd;
		for (index in 0...source.length)
			if (source.charCodeAt(index) == 10)
				lineStarts.push(index + 1);
		for (index in 0...lines.length) {
			var line = lines[index],
				lineStart = lineStarts[index],
				lineEnd = index + 1 < lineStarts.length ? lineStarts[index + 1] - 1 : source.length;
			if (lineEnd > lineStart && source.charCodeAt(lineEnd - 1) == 13)
				lineEnd--;
			var selected = lineEnd >= start && lineStart < end,
				protectedAtStart = blockComment || quote >= 0,
				trimmed = protectedAtStart ? line : StringTools.rtrim(StringTools.ltrim(line)),
				closes = !protectedAtStart && StringTools.startsWith(trimmed, "}"),
				lineDepth = closes ? Std.int(Math.max(0, depth - 1)) : depth;
			output.push(selected
				&& !protectedAtStart
				&& trimmed.length > 0 ? indentation(lineDepth, tabSize, insertSpaces) + trimmed : selected ? trimmed : line);
			var position = 0;
			while (position < line.length) {
				var code = line.charCodeAt(position),
					next = position + 1 < line.length ? line.charCodeAt(position + 1) : -1;
				if (quote >= 0) {
					if (escaped)
						escaped = false;
					else if (code == 92)
						escaped = true;
					else if (code == quote)
						quote = -1;
					position++;
					continue;
				}
				if (blockComment) {
					if (code == 42 && next == 47) {
						blockComment = false;
						position += 2;
					} else
						position++;
					continue;
				}
				if (code == 47 && next == 47)
					break;
				if (code == 47 && next == 42) {
					blockComment = true;
					position += 2;
					continue;
				}
				if (code == 34 || code == 39) {
					quote = code;
					escaped = false;
				} else if (code == 123)
					depth++;
				else if (code == 125)
					depth = Std.int(Math.max(0, depth - 1));
				position++;
			}
		}
		if (trailingNewline && output.length > 0 && output[output.length - 1] == "")
			output.pop();
		var result = output.join(newline);
		return trailingNewline ? result + newline : result;
	}

	static function indentation(depth:Int, tabSize:Int, insertSpaces:Bool):String {
		var unit = insertSpaces ? StringTools.lpad("", " ", tabSize) : "\t", result = "";
		for (_ in 0...depth)
			result += unit;
		return result;
	}
}
