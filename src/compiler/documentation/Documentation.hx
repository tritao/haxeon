package compiler.documentation;

import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;

/** Normalized Haxe documentation shared by editor and export tooling. */
typedef Documentation = {
	final raw:String;
	final markdown:String;
	final parameters:Map<String, String>;
	final deprecated:Bool;
}

/** A documentation comment paired with its source endpoint. */
typedef DocumentationComment = {
	final end:Int;
	final documentation:Documentation;
}

/** Extracts and associates Haxe `/** ... *\/` comments without affecting semantic artifacts. */
class DocumentationTools {
	public static function scan(file:SourceFile):Array<DocumentationComment> {
		var result:Array<DocumentationComment> = [], source = file.text, position = 0;
		while (position + 2 < source.length) {
			var quote = source.charAt(position);
			if (quote == "\"" || quote == "'") {
				position++;
				while (position < source.length)
					if (source.charAt(position) == "\\")
						position += 2;
					else if (source.charAt(position++) == quote)
						break;
				continue;
			}
			if (source.substr(position, 2) == "//") {
				var newline = source.indexOf("\n", position + 2);
				position = newline < 0 ? source.length : newline + 1;
				continue;
			}
			if (source.substr(position, 2) == "/*" && source.substr(position, 3) != "/**") {
				var blockClose = source.indexOf("*/", position + 2);
				position = blockClose < 0 ? source.length : blockClose + 2;
				continue;
			}
			if (source.substr(position, 3) != "/**") {
				position++;
				continue;
			}
			var close = source.indexOf("*/", position + 3);
			if (close < 0)
				break;
			var raw = source.substring(position + 3, close);
			result.push({end: file.byteOffsetForStringOffset(close + 2), documentation: normalize(raw)});
			position = close + 2;
		}
		return result;
	}

	public static function forSpan(file:SourceFile, comments:Array<DocumentationComment>, span:SourceSpan):Documentation {
		var candidate:Null<DocumentationComment> = null;
		for (comment in comments)
			if (comment.end > span.start)
				break;
			else
				candidate = comment;
		return candidate != null && isDocumentationGap(file.slice(candidate.end, span.start)) ? candidate.documentation : empty();
	}

	public static function empty():Documentation
		return {
			raw: "",
			markdown: "",
			parameters: [],
			deprecated: false
		};

	public static function normalize(raw:String):Documentation {
		var body:Array<String> = [],
			parameters:Map<String, String> = [],
			deprecated = false,
			normalized:Array<String> = [];
		for (line in raw.split("\n")) {
			var value = StringTools.trim(line);
			if (StringTools.startsWith(value, "*"))
				value = StringTools.trim(value.substring(1));
			normalized.push(value);
			if (StringTools.startsWith(value, "@param ")) {
				var content = StringTools.trim(value.substring(7)),
					separator = content.indexOf(" ");
				parameters.set(separator < 0 ? content : content.substring(0, separator),
					separator < 0 ? "" : StringTools.trim(content.substring(separator + 1)));
			} else if (StringTools.startsWith(value, "@return "))
				body.push("**Returns:** " + StringTools.trim(value.substring(8)));
			else if (StringTools.startsWith(value, "@returns "))
				body.push("**Returns:** " + StringTools.trim(value.substring(9)));
			else if (StringTools.startsWith(value, "@deprecated")) {
				deprecated = true;
				var message = StringTools.trim(value.substring(11));
				body.push("**Deprecated.**" + (message.length == 0 ? "" : " " + message));
			} else if (StringTools.startsWith(value, "@see "))
				body.push("**See:** " + StringTools.trim(value.substring(5)));
			else if (StringTools.startsWith(value, "@throws "))
				body.push("**Throws:** " + StringTools.trim(value.substring(8)));
			else if (StringTools.startsWith(value, "@exception "))
				body.push("**Throws:** " + StringTools.trim(value.substring(11)));
			else if (StringTools.startsWith(value, "@since "))
				body.push("**Since:** " + StringTools.trim(value.substring(7)));
			else
				body.push(value);
		}
		trimEmpty(body);
		trimEmpty(normalized);
		return {
			raw: normalized.join("\n"),
			markdown: body.join("\n"),
			parameters: parameters,
			deprecated: deprecated
		};
	}

	static function isDocumentationGap(gap:String):Bool {
		var trimmed = StringTools.trim(gap);
		if (trimmed.length == 0)
			return true;
		if (trimmed.indexOf(";") >= 0 || trimmed.indexOf("{") >= 0 || trimmed.indexOf("}") >= 0)
			return false;
		// Declaration spans for members begin at their name, after modifiers and
		// the `function`/`var` keyword. Metadata may also precede that prefix.
		if (StringTools.startsWith(trimmed, "@:"))
			return true;
		for (word in words(trimmed))
			if (word != "public" && word != "private" && word != "static" && word != "final" && word != "extern" && word != "override" && word != "inline"
				&& word != "dynamic" && word != "function" && word != "var")
				return false;
		return true;
	}

	static function words(value:String):Array<String> {
		var result = [], current = "";
		for (index in 0...value.length) {
			var character = value.charAt(index);
			if (character == " " || character == "\t" || character == "\r" || character == "\n") {
				if (current.length > 0) {
					result.push(current);
					current = "";
				}
			} else
				current += character;
		}
		if (current.length > 0)
			result.push(current);
		return result;
	}

	static function trimEmpty(lines:Array<String>):Void {
		while (lines.length > 0 && lines[0].length == 0)
			lines.shift();
		while (lines.length > 0 && lines[lines.length - 1].length == 0)
			lines.pop();
	}
}
