package compiler.formatter;

import compiler.Source.SourceFile;
import compiler.syntax.Token.TokenKind;
import compiler.formatter.FormatToken.FormatTokenKind;

private typedef CommentMarkers = {
	final off:Int;
	final on:Int;
	final blockComment:Bool;
}

/**
	Formatter-owned lossless lexical pass.

	The compiler lexer deliberately discards trivia. This scanner instead walks
	the original bytes once and emits every source slice, leaving compiler
	lexing unchanged on the validation and compilation hot paths.
 */
class FormatScanner {
	final file:SourceFile;
	var source:haxe.io.Bytes;
	var position:Int = 0;
	var protectedRanges:Array<{start:Int, end:Int}> = [];
	var protectedIndex:Int = 0;

	public function new(file:SourceFile)
		this.file = file;

	/** Returns a token stream whose text concatenates byte-for-byte to the input. */
	public function scan():Array<FormatToken> {
		source = file.bytes;
		position = 0;
		protectedRanges = findFormatterOffRanges();
		protectedIndex = 0;
		var result:Array<FormatToken> = [];
		while (position < source.length) {
			if (protectedIndex < protectedRanges.length && position == protectedRanges[protectedIndex].start) {
				var protectedRange = protectedRanges[protectedIndex++];
				push(result, FormatTokenKind.FormatterOff, protectedRange.start, protectedRange.end);
				position = protectedRange.end;
				continue;
			}
			var code = source.get(position);
			if (code == "\r".code || code == "\n".code) {
				var newlineEnd = position + 1;
				if (code == "\r".code && newlineEnd < source.length && source.get(newlineEnd) == "\n".code)
					newlineEnd++;
				push(result, FormatTokenKind.Newline, position, newlineEnd);
				position = newlineEnd;
				continue;
			}
			if (code == " ".code || code == "\t".code) {
				var whitespaceEnd = position + 1;
				while (whitespaceEnd < source.length && (source.get(whitespaceEnd) == " ".code || source.get(whitespaceEnd) == "\t".code))
					whitespaceEnd++;
				push(result, FormatTokenKind.Whitespace, position, whitespaceEnd);
				position = whitespaceEnd;
				continue;
			}
			if (isDirectiveStart(position)) {
				var directiveEnd = position;
				while (directiveEnd < source.length && source.get(directiveEnd) != "\r".code && source.get(directiveEnd) != "\n".code)
					directiveEnd++;
				push(result, FormatTokenKind.Directive, position, directiveEnd);
				position = directiveEnd;
				continue;
			}
			if (code == "/".code && position + 1 < source.length && source.get(position + 1) == "/".code) {
				var lineEnd = position + 2;
				while (lineEnd < source.length && source.get(lineEnd) != "\r".code && source.get(lineEnd) != "\n".code)
					lineEnd++;
				var lineText = file.slice(position, lineEnd),
					lineKind = StringTools.startsWith(lineText, "///") ? FormatTokenKind.DocComment : FormatTokenKind.LineComment;
				push(result, lineKind, position, lineEnd);
				position = lineEnd;
				continue;
			}
			if (code == "/".code && position + 1 < source.length && source.get(position + 1) == "*".code) {
				var blockEnd = position + 2;
				while (blockEnd + 1 < source.length && !(source.get(blockEnd) == "*".code && source.get(blockEnd + 1) == "/".code))
					blockEnd++;
				if (blockEnd + 1 < source.length)
					blockEnd += 2;
				var blockText = file.slice(position, blockEnd),
					blockKind = StringTools.startsWith(blockText, "/**") ? FormatTokenKind.DocComment : FormatTokenKind.BlockComment;
				push(result, blockKind, position, blockEnd);
				position = blockEnd;
				continue;
			}

			var start = position;
			if (code == "\"".code || code == "'".code) {
				position++;
				scanString(code);
				push(result, FormatTokenKind.Syntax(TokenKind.StringLiteral), start, position);
				continue;
			}
			if (code == "~".code && position + 1 < source.length && source.get(position + 1) == "/".code) {
				position += 2;
				scanRegex();
				while (position < source.length && isIdentifierPart(source.get(position)))
					position++;
				push(result, FormatTokenKind.Syntax(TokenKind.RegexLiteral), start, position);
				continue;
			}
			if (isIdentifierStart(code)) {
				position++;
				while (position < source.length && isIdentifierPart(source.get(position)))
					position++;
				var identifier = file.slice(start, position);
				push(result, FormatTokenKind.Syntax(keyword(identifier)), start, position);
				continue;
			}
			if (isDigit(code)) {
				position++;
				if (code == "0".code
					&& position < source.length
					&& (source.get(position) == "x".code || source.get(position) == "X".code)) {
					position++;
					while (position < source.length && isHexDigit(source.get(position)))
						position++;
					push(result, FormatTokenKind.Syntax(TokenKind.Integer), start, position);
					continue;
				}
				while (position < source.length && isDigit(source.get(position)))
					position++;
				var numberKind = TokenKind.Integer;
				if (position + 1 < source.length && source.get(position) == ".".code && isDigit(source.get(position + 1))) {
					numberKind = TokenKind.Float;
					position++;
					while (position < source.length && isDigit(source.get(position)))
						position++;
				}
				push(result, FormatTokenKind.Syntax(numberKind), start, position);
				continue;
			}

			var syntaxKind = scanPunctuation();
			if (syntaxKind != null)
				push(result, FormatTokenKind.Syntax(syntaxKind), start, position);
			else {
				position = start + 1;
				push(result, FormatTokenKind.Whitespace, start, position);
			}
		}
		return result;
	}

	/** The scanner's fundamental losslessness oracle. */
	public function roundTrip(tokens:Array<FormatToken>):String {
		var output = new StringBuf();
		for (token in tokens)
			output.add(token.text);
		return output.toString();
	}

	function scanPunctuation():Null<TokenKind> {
		var character = String.fromCharCode(source.get(position++));
		return switch character {
			case "(": TokenKind.LeftParen;
			case ")": TokenKind.RightParen;
			case "{": TokenKind.LeftBrace;
			case "}": TokenKind.RightBrace;
			case ":": TokenKind.Colon;
			case ";": TokenKind.Semicolon;
			case ",": TokenKind.Comma;
			case ".": TokenKind.Dot;
			case "[": TokenKind.LeftBracket;
			case "]": TokenKind.RightBracket;
			case "?": TokenKind.Question;
			case "@": TokenKind.At;
			case "$": TokenKind.Dollar;
			case "~": TokenKind.BitNot;
			case "=": twoCharacter("=", TokenKind.EqualEqual, TokenKind.Assign);
			case "<": twoCharacter("=", TokenKind.LessEqual, TokenKind.Less);
			case ">": twoCharacter("=", TokenKind.GreaterEqual, TokenKind.Greater);
			case "!": twoCharacter("=", TokenKind.NotEqual, TokenKind.Not);
			case "&": if (consume("&")) TokenKind.AndAnd else if (consume("=")) TokenKind.AndAssign else TokenKind.Ampersand;
			case "|": if (consume("|")) TokenKind.OrOr else if (consume("=")) TokenKind.OrAssign else TokenKind.Pipe;
			case "^": if (consume("=")) TokenKind.XorAssign else TokenKind.Caret;
			case "+": if (consume("=")) TokenKind.PlusAssign else if (consume("+")) TokenKind.Increment else TokenKind.Plus;
			case "-": if (consume(">")) TokenKind.Arrow else if (consume("=")) TokenKind.MinusAssign else if (consume("-")) TokenKind.Decrement else
					TokenKind.Minus;
			case "*": if (consume("=")) TokenKind.StarAssign else TokenKind.Star;
			case "/": if (consume("=")) TokenKind.SlashAssign else TokenKind.Slash;
			case "%": if (consume("=")) TokenKind.PercentAssign else TokenKind.Percent;
			default: null;
		};
	}

	function twoCharacter(expected:String, pair:TokenKind, single:TokenKind):TokenKind
		return consume(expected) ? pair : single;

	function consume(value:String):Bool {
		if (position < source.length && source.get(position) == value.charCodeAt(0)) {
			position++;
			return true;
		}
		return false;
	}

	function scanString(quote:Int):Void {
		while (position < source.length) {
			var current = source.get(position++);
			if (current == "\\".code) {
				if (position < source.length)
					position++;
				continue;
			}
			if (quote == "'".code && current == "$".code && position < source.length && source.get(position) == "{".code) {
				position++;
				scanInterpolation();
				continue;
			}
			if (current == quote)
				return;
		}
	}

	function scanInterpolation():Void {
		var depth = 1;
		while (position < source.length) {
			var current = source.get(position++);
			if (current == "\"".code || current == "'".code) {
				scanString(current);
				continue;
			}
			if (current == "/".code && position < source.length) {
				var next = source.get(position);
				if (next == "/".code) {
					position++;
					while (position < source.length && source.get(position) != "\n".code)
						position++;
					continue;
				}
				if (next == "*".code) {
					position++;
					while (position + 1 < source.length && !(source.get(position) == "*".code && source.get(position + 1) == "/".code))
						position++;
					if (position + 1 < source.length)
						position += 2;
					continue;
				}
			}
			if (current == "{".code)
				depth++;
			else if (current == "}".code) {
				depth--;
				if (depth == 0)
					return;
			}
		}
	}

	function scanRegex():Void {
		var escaped = false, characterClass = false;
		while (position < source.length) {
			var current = source.get(position++);
			if (escaped) {
				escaped = false;
				continue;
			}
			if (current == "\\".code) {
				escaped = true;
				continue;
			}
			if (current == "[".code)
				characterClass = true;
			else if (current == "]".code)
				characterClass = false;
			else if (current == "/".code && !characterClass)
				return;
		}
	}

	function findFormatterOffRanges():Array<{start:Int, end:Int}> {
		var result:Array<{start:Int, end:Int}> = [], position = 0, protectedStart = -1, blockComment = false;
		while (position < source.length) {
			var lineStart = position;
			while (position < source.length && source.get(position) != "\n".code)
				position++;
			var lineEnd = position,
				text = file.slice(lineStart, lineEnd),
				markers = commentMarkers(text, blockComment),
				off = markers.off,
				on = markers.on;
			blockComment = markers.blockComment;
			if (protectedStart < 0 && off >= 0) {
				protectedStart = lineStart;
				if (on >= 0 && on > off) {
					if (lineEnd > lineStart && source.get(lineEnd - 1) == "\r".code)
						lineEnd--;
					result.push({start: protectedStart, end: lineEnd});
					protectedStart = -1;
				}
			} else if (protectedStart >= 0 && on >= 0) {
				if (lineEnd > lineStart && source.get(lineEnd - 1) == "\r".code)
					lineEnd--;
				result.push({start: protectedStart, end: lineEnd});
				protectedStart = -1;
			}
			if (position < source.length)
				position++;
		}
		if (protectedStart >= 0)
			result.push({start: protectedStart, end: source.length});
		return result;
	}

	static function commentMarkers(text:String, initialBlockComment:Bool):CommentMarkers {
		var quote = 0, escaped = false, blockComment = initialBlockComment, off = -1, on = -1, index = 0;
		while (index < text.length) {
			var code = text.charCodeAt(index),
				next = index + 1 < text.length ? text.charCodeAt(index + 1) : -1;
			if (blockComment) {
				if (off < 0)
					off = text.indexOf("@formatter:off", index);
				if (on < 0)
					on = text.indexOf("@formatter:on", index);
				if (code == "*".code && next == "/".code) {
					blockComment = false;
					index += 2;
				} else
					index++;
				continue;
			}
			if (quote != 0) {
				if (escaped)
					escaped = false;
				else if (code == "\\".code)
					escaped = true;
				else if (code == quote)
					quote = 0;
				index++;
				continue;
			}
			if (code == "\"".code || code == "'".code) {
				quote = code;
				index++;
				continue;
			}
			if (code == "/".code && next == "/".code) {
				if (off < 0)
					off = text.indexOf("@formatter:off", index + 2);
				if (on < 0)
					on = text.indexOf("@formatter:on", index + 2);
				break;
			}
			if (code == "/".code && next == "*".code) {
				blockComment = true;
				index += 2;
				continue;
			}
			index++;
		}
		return {off: off, on: on, blockComment: blockComment};
	}

	function isDirectiveStart(offset:Int):Bool {
		if (source.get(offset) != "#".code)
			return false;
		var cursor = offset - 1;
		while (cursor >= 0 && source.get(cursor) != "\n".code) {
			var code = source.get(cursor);
			if (code != " ".code && code != "\t".code && code != "\r".code)
				return false;
			cursor--;
		}
		return true;
	}

	/** Returns the directive keyword without its condition or surrounding trivia. */
	public static function directiveName(text:String):String {
		var index = 0;
		while (index < text.length
			&& (text.charCodeAt(index) == "#".code || text.charCodeAt(index) == " ".code || text.charCodeAt(index) == "\t".code
				|| text.charCodeAt(index) == "\r".code))
			index++;
		var start = index;
		while (index < text.length) {
			var code = text.charCodeAt(index);
			if (code == " ".code || code == "\t".code || code == "\r".code || code == "(".code)
				break;
			index++;
		}
		return text.substring(start, index);
	}

	function push(result:Array<FormatToken>, kind:FormatTokenKind, start:Int, end:Int):Void
		if (end > start)
			result.push({
				kind: kind,
				text: file.slice(start, end),
				start: start,
				end: end
			});

	static function keyword(value:String):TokenKind {
		return switch value {
			case "package": TokenKind.Package;
			case "import": TokenKind.Import;
			case "typedef": TokenKind.Typedef;
			case "class": TokenKind.Class;
			case "interface": TokenKind.Interface;
			case "enum": TokenKind.Enum;
			case "extends": TokenKind.Extends;
			case "implements": TokenKind.Implements;
			case "public": TokenKind.Public;
			case "private": TokenKind.Private;
			case "static": TokenKind.Static;
			case "inline": TokenKind.Inline;
			case "final": TokenKind.Final;
			case "new": TokenKind.New;
			case "this": TokenKind.This;
			case "Void": TokenKind.Void;
			case "function": TokenKind.Function;
			case "var": TokenKind.Var;
			case "return": TokenKind.Return;
			case "throw": TokenKind.Throw;
			case "try": TokenKind.Try;
			case "catch": TokenKind.Catch;
			case "if": TokenKind.If;
			case "else": TokenKind.Else;
			case "while": TokenKind.While;
			case "do": TokenKind.Do;
			case "for": TokenKind.For;
			case "in": TokenKind.In;
			case "break": TokenKind.Break;
			case "continue": TokenKind.Continue;
			case "switch": TokenKind.Switch;
			case "case": TokenKind.Case;
			case "default": TokenKind.Default;
			case "true": TokenKind.BoolTrue;
			case "false": TokenKind.BoolFalse;
			case "Int": TokenKind.TypeInt;
			case "Bool": TokenKind.TypeBool;
			case "Float": TokenKind.TypeFloat;
			case "String": TokenKind.TypeString;
			default: TokenKind.Identifier;
		};
	}

	static inline function isDigit(code:Int):Bool
		return code >= "0".code && code <= "9".code;

	static inline function isIdentifierStart(code:Int):Bool
		return code >= "A".code && code <= "Z".code || code >= "a".code && code <= "z".code || code == "_".code;

	static inline function isIdentifierPart(code:Int):Bool
		return isIdentifierStart(code) || isDigit(code);

	static inline function isHexDigit(code:Int):Bool
		return isDigit(code) || code >= "A".code && code <= "F".code || code >= "a".code && code <= "f".code;
}
