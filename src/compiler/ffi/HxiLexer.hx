package compiler.ffi;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.documentation.Documentation.DocumentationComment;
import compiler.documentation.Documentation.DocumentationTools;

typedef HxiToken = {
	final text:String;
	final span:SourceSpan;
}

typedef HxiLexResult = {
	final tokens:Array<HxiToken>;
	final comments:Array<DocumentationComment>;
}

/** Tokenizes HXI source while preserving source spans and documentation comments. */
class HxiLexer {
	public static function lex(source:SourceFile):HxiLexResult {
		var result:Array<HxiToken> = [], comments:Array<DocumentationComment> = [], bytes = source.bytes, position = 0;
		while (position < bytes.length) {
			var code = bytes.get(position);
			if (code == " ".code || code == "\t".code || code == "\n".code || code == "\r".code) {
				position++;
				continue;
			}
			if (code == "/".code && position + 1 < bytes.length && bytes.get(position + 1) == "/".code) {
				position += 2;
				while (position < bytes.length && bytes.get(position) != "\n".code)
					position++;
				continue;
			}
			if (code == "/".code && position + 1 < bytes.length && bytes.get(position + 1) == "*".code) {
				var commentStart = position;
				position += 2;
				while (position + 1 < bytes.length && !(bytes.get(position) == "*".code && bytes.get(position + 1) == "/".code))
					position++;
				if (position + 1 >= bytes.length)
					throw new CompileError(new Diagnostic("E3001", "Unterminated HXI block comment", source.span(commentStart, position)));
				if (commentStart + 2 < bytes.length && bytes.get(commentStart + 2) == "*".code && position >= commentStart + 3)
					comments.push({end: position + 2, documentation: DocumentationTools.normalize(source.slice(commentStart + 3, position))});
				position += 2;
				continue;
			}
			var start = position;
			if (code == "\"".code) {
				position++;
				while (position < bytes.length && bytes.get(position) != "\"".code)
					position += bytes.get(position) == "\\".code && position + 1 < bytes.length ? 2 : 1;
				if (position >= bytes.length)
					throw new CompileError(new Diagnostic("E3001", "Unterminated HXI string", source.span(start, position)));
				position++;
			} else if ((code >= "A".code && code <= "Z".code) || (code >= "a".code && code <= "z".code) || code == "_".code) {
				position++;
				while (position < bytes.length) {
					code = bytes.get(position);
					if (!((code >= "A".code && code <= "Z".code)
						|| (code >= "a".code && code <= "z".code)
						|| (code >= "0".code && code <= "9".code)
						|| code == "_".code))
						break;
					position++;
				}
			} else if ((code >= "0".code && code <= "9".code)
				|| (code == "-".code && position + 1 < bytes.length && bytes.get(position + 1) >= "0".code && bytes.get(position + 1) <= "9".code)) {
				position++;
				if (code == "0".code && position < bytes.length && (bytes.get(position) == "x".code || bytes.get(position) == "X".code)) {
					position++;
					while (position < bytes.length
						&& ((bytes.get(position) >= "0".code && bytes.get(position) <= "9".code)
							|| (bytes.get(position) >= "A".code && bytes.get(position) <= "F".code)
							|| (bytes.get(position) >= "a".code && bytes.get(position) <= "f".code)))
						position++;
				} else
					while (position < bytes.length && bytes.get(position) >= "0".code && bytes.get(position) <= "9".code)
						position++;
			} else if (code == "-".code && position + 1 < bytes.length && bytes.get(position + 1) == ">".code)
				position += 2;
			else if ((code == "<".code || code == ">".code) && position + 1 < bytes.length && bytes.get(position + 1) == code)
				position += 2;
			else if (isPunctuation(code))
				position++;
			else
				throw new CompileError(new Diagnostic("E3001", 'Unexpected HXI character "${String.fromCharCode(code)}"', source.span(start, start + 1)));
			result.push({text: source.slice(start, position), span: source.span(start, position)});
		}
		return {tokens: result, comments: comments};
	}

	static inline function isPunctuation(code:Int):Bool
		return code == "{".code || code == "}".code || code == "(".code || code == ")".code || code == "<".code || code == ">".code || code == ":".code
			|| code == ",".code || code == ";".code || code == "=".code || code == "@".code || code == "|".code || code == "-".code;
}
