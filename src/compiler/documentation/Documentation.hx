package compiler.documentation;

import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;

/** Normalized Haxe documentation shared by editor and export tooling. */
typedef Documentation = {
	final raw:String;
	final lines:Array<String>;
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
		var result:Array<DocumentationComment> = [], bytes = file.bytes, position = 0;
		while (position + 2 < bytes.length) {
			var code = bytes.get(position);
			if (code == "\"".code || code == "'".code) {
				position++;
				while (position < bytes.length)
					if (bytes.get(position) == "\\".code)
						position += 2;
					else if (bytes.get(position++) == code)
						break;
				continue;
			}
			if (code != "/".code || position + 1 >= bytes.length) {
				position++;
				continue;
			}
			var next = bytes.get(position + 1);
			if (next == "/".code) {
				position += 2;
				while (position < bytes.length && bytes.get(position) != "\n".code)
					position++;
				continue;
			}
			if (next != "*".code) {
				position++;
				continue;
			}
			var commentStart = position,
				documentation = position + 2 < bytes.length && bytes.get(position + 2) == "*".code;
			position += 2;
			while (position + 1 < bytes.length && !(bytes.get(position) == "*".code && bytes.get(position + 1) == "/".code))
				position++;
			if (position + 1 >= bytes.length) {
				if (documentation)
					break;
				position = bytes.length;
				continue;
			}
			// Keep the historical `/**/` behavior: it is a block comment, not a
			// documentation comment, because the closing marker starts too early.
			if (documentation && position >= commentStart + 3)
				result.push({end: position + 2, documentation: normalize(file.slice(commentStart + 3, position))});
			position += 2;
		}
		return result;
	}

	public static function forSpan(file:SourceFile, comments:Array<DocumentationComment>, span:SourceSpan):Documentation {
		var low = 0, high = comments.length;
		while (low < high) {
			var middle = low + ((high - low) >> 1);
			if (comments[middle].end <= span.start)
				low = middle + 1;
			else
				high = middle;
		}
		var candidate:Null<DocumentationComment> = low == 0 ? null : comments[low - 1];
		return candidate != null && isDocumentationGap(file.slice(candidate.end, span.start)) ? candidate.documentation : empty();
	}

	public static function empty():Documentation
		return {
			raw: "",
			lines: [],
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
			lines: normalized,
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
		var position = 0;
		while (position < trimmed.length) {
			while (position < trimmed.length && isWhitespace(trimmed.charAt(position)))
				position++;
			if (position == trimmed.length)
				break;
			var end = position;
			while (end < trimmed.length && !isWhitespace(trimmed.charAt(end)))
				end++;
			if (!isDeclarationWord(trimmed.substring(position, end)))
				return false;
			position = end;
		}
		return true;
	}

	static inline function isWhitespace(value:String):Bool
		return value == " " || value == "\t" || value == "\r" || value == "\n";

	static function isDeclarationWord(value:String):Bool
		return switch value {
			case "public" | "private" | "static" | "final" | "extern" | "override" | "inline" | "dynamic" | "function" | "var": true;
			case _: false;
		};

	static function trimEmpty(lines:Array<String>):Void {
		while (lines.length > 0 && lines[0].length == 0)
			lines.shift();
		while (lines.length > 0 && lines[lines.length - 1].length == 0)
			lines.pop();
	}
}
