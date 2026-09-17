package compiler.syntax;

import compiler.Diagnostic.CompileError;
import compiler.Diagnostic.Diagnostic;
import compiler.Diagnostic.DiagnosticOrigin;
import compiler.Diagnostic.DiagnosticSeverity;
import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.syntax.Token.TokenKind;

/** Lossless lexical categories shared by the compiler and formatter. */
enum SyntaxTokenKind {
	Syntax(kind:TokenKind);
	Whitespace;
	Newline;
	LineComment;
	BlockComment;
	DocComment;
	Directive;
	Unknown;
}

/** One lossless source slice. Text is derived from the source whenever possible. */
class LosslessToken {
	public final kind:SyntaxTokenKind;
	public final span:SourceSpan;
	final replacementText:Null<String>;

	public function new(kind:SyntaxTokenKind, span:SourceSpan, ?replacementText:String) {
		this.kind = kind;
		this.span = span;
		this.replacementText = replacementText;
	}

	public var text(get, never):String;

	function get_text():String
		return replacementText == null ? span.file.slice(span.start, span.end) : replacementText;
}

/**
		The one source scanner used by compiler and formatter front ends.

		The default mode is lossless and permissive: malformed literals and unknown
		bytes are still represented as source slices. Strict mode retains the
		compiler lexer's existing lexical diagnostics through the Lexer adapter.
 */
class SyntaxScanner {
	public final file:SourceFile;
	public final sourceLength:Int;
	final source:haxe.io.Bytes;
	final sourceIsFile:Bool;
	final checkpointCallback:Null<Void->Void>;
	final strict:Bool;
	final includeTrivia:Bool;
	var position:Int = 0;

	public function new(file:SourceFile, ?source:String, ?checkpoint:Void->Void, strict:Bool = false, includeTrivia:Bool = true) {
		this.file = file;
		this.sourceIsFile = source == null || source == file.text;
		this.source = sourceIsFile ? file.bytes : haxe.io.Bytes.ofString(source);
		this.sourceLength = this.source.length;
		this.checkpointCallback = checkpoint;
		this.strict = strict;
		this.includeTrivia = includeTrivia;
	}

	/** Returns slices that cover the input in order without dropping trivia. */
	public function scan():Array<LosslessToken> {
		var result:Array<LosslessToken> = [];
		while (position < source.length) {
			checkpoint();
			var code = source.get(position);
			if (code == "\r".code || code == "\n".code) {
				var newlineEnd = position + 1;
				if (code == "\r".code && newlineEnd < source.length && source.get(newlineEnd) == "\n".code)
					newlineEnd++;
				emit(result, SyntaxTokenKind.Newline, position, newlineEnd);
				position = newlineEnd;
				continue;
			}
			if (code == " ".code || code == "\t".code) {
				var whitespaceEnd = position + 1;
				while (whitespaceEnd < source.length && (source.get(whitespaceEnd) == " ".code || source.get(whitespaceEnd) == "\t".code))
					whitespaceEnd++;
				emit(result, SyntaxTokenKind.Whitespace, position, whitespaceEnd);
				position = whitespaceEnd;
				continue;
			}
			if (isDirectiveStart(position)) {
				var directiveEnd = position;
				while (directiveEnd < source.length && source.get(directiveEnd) != "\r".code && source.get(directiveEnd) != "\n".code)
					directiveEnd++;
				if (strict)
					fail('Unexpected character "${text(position, position + 1)}"', position, position + 1);
				emit(result, SyntaxTokenKind.Directive, position, directiveEnd);
				position = directiveEnd;
				continue;
			}
			if (code == "/".code && position + 1 < source.length) {
				var next = source.get(position + 1);
				if (next == "/".code) {
					var lineEnd = position + 2;
					while (lineEnd < source.length && source.get(lineEnd) != "\r".code && source.get(lineEnd) != "\n".code)
						lineEnd++;
					var lineText = text(position, lineEnd),
						lineKind = StringTools.startsWith(lineText, "///") ? SyntaxTokenKind.DocComment : SyntaxTokenKind.LineComment;
					emit(result, lineKind, position, lineEnd);
					position = lineEnd;
					continue;
				}
				if (next == "*".code) {
					var commentStart = position;
					position += 2;
					while (position + 1 < source.length && !(source.get(position) == "*".code && source.get(position + 1) == "/".code))
						position++;
					if (position + 1 >= source.length) {
						if (strict)
							throw new CompileError(new Diagnostic("E0001", "Unterminated block comment", file.span(commentStart, position),
								DiagnosticSeverity.Error, [
									{
										id: "close-block-comment",
										title: "Close block comment",
										edits: [{span: file.span(position, position), replacement: "*/"}]
									}
								], DiagnosticOrigin.Lexical));
						emit(result, commentKind(text(commentStart, position)), commentStart, position);
						continue;
					}
					position += 2;
					emit(result, commentKind(text(commentStart, position)), commentStart, position);
					continue;
				}
			}

			var start = position;
			if (code == "~".code && position + 1 < source.length && source.get(position + 1) == "/".code) {
				position += 2;
				var closed = scanRegex();
				while (position < source.length && isIdentifierPart(source.get(position)))
					position++;
				if (!closed && strict)
					fail("Unterminated regular expression literal", start, position);
				emit(result, SyntaxTokenKind.Syntax(TokenKind.RegexLiteral), start, position);
				continue;
			}
			if (code == "\"".code || code == "'".code) {
				var quote = code;
				position++;
				var closed = scanString(quote);
				if (!closed && strict)
					throw new CompileError(new Diagnostic("E0001", "Unterminated string literal", file.span(start, position), DiagnosticSeverity.Error, [
						{
							id: "close-string-literal",
							title: "Close string literal",
							edits: [{span: file.span(position, position), replacement: String.fromCharCode(quote)}]
						}
					], DiagnosticOrigin.Lexical));
				emit(result, SyntaxTokenKind.Syntax(TokenKind.StringLiteral), start, position);
				continue;
			}
			if (isIdentifierStart(code)) {
				position++;
				while (position < source.length && isIdentifierPart(source.get(position)))
					position++;
				emit(result, SyntaxTokenKind.Syntax(keyword(text(start, position))), start, position);
				continue;
			}
			if (isDigit(code)) {
				position++;
				if (code == "0".code && position < source.length && (source.get(position) == "x".code || source.get(position) == "X".code)) {
					position++;
					var digitsStart = position;
					while (position < source.length && isHexDigit(source.get(position)))
						position++;
					if (position == digitsStart && strict)
						fail("Hexadecimal literal requires at least one digit", start, position);
					emit(result, SyntaxTokenKind.Syntax(TokenKind.Integer), start, position);
					continue;
				}
				while (position < source.length && isDigit(source.get(position)))
					position++;
				var kind = TokenKind.Integer;
				if (position + 1 < source.length && source.get(position) == ".".code && isDigit(source.get(position + 1))) {
					kind = TokenKind.Float;
					position++;
					while (position < source.length && isDigit(source.get(position)))
						position++;
				}
				if (position < source.length && (source.get(position) == "e".code || source.get(position) == "E".code)) {
					kind = TokenKind.Float;
					position++;
					if (position < source.length && (source.get(position) == "+".code || source.get(position) == "-".code))
						position++;
					var exponentStart = position;
					while (position < source.length && isDigit(source.get(position)))
						position++;
					if (position == exponentStart && strict)
						fail("Exponent requires at least one digit", start, position);
				}
				emit(result, SyntaxTokenKind.Syntax(kind), start, position);
				continue;
			}
			if (code >= 0x80) {
				var end = position + utf8Width(code);
				if (end > source.length)
					end = source.length;
				if (strict)
					fail('Unexpected character "${text(position, end)}"', position, end);
				emit(result, SyntaxTokenKind.Unknown, position, end);
				position = end;
				continue;
			}

			position++;
			var character = String.fromCharCode(code),
				kind = punctuation(character);
			if (kind == null) {
				if (strict)
					fail('Unexpected character "${character}"', start, position);
				emit(result, SyntaxTokenKind.Unknown, start, position);
			} else {
				var punctuationKind = kind;
				if (character == "=" && consume("="))
					punctuationKind = TokenKind.EqualEqual;
				else if (character == "<" && consume("="))
					punctuationKind = TokenKind.LessEqual;
				else if (character == ">" && consume("="))
					punctuationKind = TokenKind.GreaterEqual;
				else if (character == "!" && consume("="))
					punctuationKind = TokenKind.NotEqual;
				else if (character == "&") {
					if (consume("&")) punctuationKind = TokenKind.AndAnd;
					else if (consume("=")) punctuationKind = TokenKind.AndAssign;
				} else if (character == "|") {
					if (consume("|")) punctuationKind = TokenKind.OrOr;
					else if (consume("=")) punctuationKind = TokenKind.OrAssign;
				} else if (character == "^") {
					if (consume("=")) punctuationKind = TokenKind.XorAssign;
				} else if (character == "+") {
					if (consume("=")) punctuationKind = TokenKind.PlusAssign;
					else if (consume("+")) punctuationKind = TokenKind.Increment;
				} else if (character == "-") {
					if (consume(">")) punctuationKind = TokenKind.Arrow;
					else if (consume("=")) punctuationKind = TokenKind.MinusAssign;
					else if (consume("-")) punctuationKind = TokenKind.Decrement;
				} else if (character == "*") {
					if (consume("=")) punctuationKind = TokenKind.StarAssign;
				} else if (character == "/") {
					if (consume("=")) punctuationKind = TokenKind.SlashAssign;
				} else if (character == "%") {
					if (consume("=")) punctuationKind = TokenKind.PercentAssign;
				} else if (character == "?") {
					if (consume("?")) punctuationKind = TokenKind.NullCoalesce;
				}
				emit(result, SyntaxTokenKind.Syntax(punctuationKind), start, position);
			}
		}
		return result;
	}

	function emit(result:Array<LosslessToken>, kind:SyntaxTokenKind, start:Int, end:Int):Void {
		if (end <= start)
			return;
		if (!includeTrivia)
			switch kind {
				case SyntaxTokenKind.Whitespace, SyntaxTokenKind.Newline,
					SyntaxTokenKind.LineComment, SyntaxTokenKind.BlockComment, SyntaxTokenKind.DocComment:
					return;
				default:
			}
		var replacement = sourceIsFile ? null : text(start, end);
		result.push(new LosslessToken(kind, file.span(start, end), replacement));
	}

	function fail(message:String, start:Int, end:Int):Void
		throw new CompileError(new Diagnostic("E0001", message, file.span(start, end), DiagnosticSeverity.Error, null, DiagnosticOrigin.Lexical));

	function scanString(quote:Int):Bool {
		while (position < source.length) {
			checkpoint();
			var current = source.get(position++);
			if (current == "\\".code) {
				if (position < source.length)
					position++;
				continue;
			}
			if (quote == "'".code && current == "$".code && position < source.length && source.get(position) == "{".code) {
				position++;
				if (!scanInterpolation())
					return false;
				continue;
			}
			if (current == quote)
				return true;
		}
		return false;
	}

	function scanInterpolation():Bool {
		var depth = 1;
		while (position < source.length) {
			checkpoint();
			var current = source.get(position++);
			if (current == "\"".code || current == "'".code) {
				if (!scanString(current))
					return false;
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
					if (position + 1 >= source.length)
						return false;
					position += 2;
					continue;
				}
			}
			if (current == "{".code)
				depth++;
			else if (current == "}".code) {
				depth--;
				if (depth == 0)
					return true;
			}
		}
		return false;
	}

	function scanRegex():Bool {
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
				return true;
		}
		return false;
	}

	function consume(value:String):Bool {
		if (position < source.length && source.get(position) == value.charCodeAt(0)) {
			position++;
			return true;
		}
		return false;
	}

	function punctuation(character:String):Null<TokenKind>
		return switch character {
			case "(": TokenKind.LeftParen;
			case ")": TokenKind.RightParen;
			case "{": TokenKind.LeftBrace;
			case "}": TokenKind.RightBrace;
			case ":": TokenKind.Colon;
			case ";": TokenKind.Semicolon;
			case ",": TokenKind.Comma;
			case ".": TokenKind.Dot;
			case "=": TokenKind.Assign;
			case "<": TokenKind.Less;
			case ">": TokenKind.Greater;
			case "!": TokenKind.Not;
			case "~": TokenKind.BitNot;
			case "&": TokenKind.Ampersand;
			case "|": TokenKind.Pipe;
			case "^": TokenKind.Caret;
			case "[": TokenKind.LeftBracket;
			case "]": TokenKind.RightBracket;
			case "?": TokenKind.Question;
			case "@": TokenKind.At;
			case "$": TokenKind.Dollar;
			case "+": TokenKind.Plus;
			case "-": TokenKind.Minus;
			case "*": TokenKind.Star;
			case "/": TokenKind.Slash;
			case "%": TokenKind.Percent;
			default: null;
		};

	function commentKind(value:String):SyntaxTokenKind
		return StringTools.startsWith(value, "/**") ? SyntaxTokenKind.DocComment : SyntaxTokenKind.BlockComment;

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

	static inline function utf8Width(code:Int):Int
		return code < 0xE0 ? 2 : code < 0xF0 ? 3 : 4;

	static function keyword(value:String):TokenKind
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

	static inline function isDigit(code:Int):Bool
		return code >= "0".code && code <= "9".code;

	static inline function isIdentifierStart(code:Int):Bool
		return code >= "A".code && code <= "Z".code || code >= "a".code && code <= "z".code || code == "_".code;

	static inline function isIdentifierPart(code:Int):Bool
		return isIdentifierStart(code) || isDigit(code);

	static inline function isHexDigit(code:Int):Bool
		return isDigit(code) || code >= "A".code && code <= "F".code || code >= "a".code && code <= "f".code;

	inline function text(start:Int, end:Int):String
		return source.getString(start, end - start);

	inline function checkpoint():Void {
		if (checkpointCallback != null)
			checkpointCallback();
	}
}
