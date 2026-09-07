package compiler.syntax;

import compiler.syntax.Token.TokenKind;
import compiler.Source.SourceFile;
import compiler.Diagnostic.CompileError;
import compiler.Diagnostic.DiagnosticSeverity;

/** Converts one source file into a positioned token stream or a lexical diagnostic. */
class Lexer {
	final file:SourceFile;
	final source:haxe.io.Bytes;
	var position:Int = 0;

	public function new(file:SourceFile, ?source:String) {
		this.file = file;
		this.source = source == null || source == file.text ? file.bytes : haxe.io.Bytes.ofString(source);
	}

	public function tokenize():Array<Token> {
		var tokens = [];
		while (position < source.length) {
			var code = source.get(position);
			if (isWhitespace(code)) {
				position++;
				continue;
			}
			if (code == "/".code && position + 1 < source.length) {
				var next = source.get(position + 1);
				if (next == "/".code) {
					position += 2;
					while (position < source.length && source.get(position) != "\n".code)
						position++;
					continue;
				}
				if (next == "*".code) {
					var commentStart = position;
					position += 2;
					while (position + 1 < source.length && !(source.get(position) == "*".code && source.get(position + 1) == "/".code))
						position++;
					if (position + 1 >= source.length)
						throw new CompileError(new Diagnostic("E0001", "Unterminated block comment", file.span(commentStart, position),
							DiagnosticSeverity.Error, [
							{
								id: "close-block-comment",
								title: "Close block comment",
								edits: [{span: file.span(position, position), replacement: "*/"}]
							}
						]));
					position += 2;
					continue;
				}
			}
			var start = position;
			if (code == "~".code && position + 1 < source.length && source.get(position + 1) == "/".code) {
				position += 2;
				var escaped = false, characterClass = false, closed = false;
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
					else if (current == "/".code && !characterClass) {
						closed = true;
						break;
					}
				}
				if (!closed)
					throw new CompileError(new Diagnostic("E0001", "Unterminated regular expression literal", file.span(start, position)));
				while (position < source.length && isIdentifierPart(source.get(position)))
					position++;
				tokens.push(new Token(TokenKind.RegexLiteral, text(start, position), file.span(start, position)));
				continue;
			}
			if (code == "\"".code || code == "'".code) {
				var quote = code;
				position++;
				var escaped = false, closed = false;
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
					if (current == quote) {
						closed = true;
						break;
					}
				}
				if (!closed)
					throw new CompileError(new Diagnostic("E0001", "Unterminated string literal", file.span(start, position), DiagnosticSeverity.Error, [
						{id: "close-string-literal", title: "Close string literal", edits: [{span: file.span(position,
							position), replacement: String.fromCharCode(quote)}]}
					]));
				tokens.push(new Token(TokenKind.StringLiteral, text(start, position), file.span(start, position)));
				continue;
			}
			if (isIdentifierStart(code)) {
				position++;
				while (position < source.length && isIdentifierPart(source.get(position)))
					position++;
				var value = text(start, position);
				tokens.push(new Token(keyword(value), value, file.span(start, position)));
				continue;
			}
			if (isDigit(code)) {
				position++;
				if (code == "0".code
					&& position < source.length
					&& (source.get(position) == "x".code || source.get(position) == "X".code)) {
					position++;
					var digitsStart = position;
					while (position < source.length && isHexDigit(source.get(position)))
						position++;
					if (position == digitsStart)
						throw new CompileError(new Diagnostic("E0001", "Hexadecimal literal requires at least one digit", file.span(start, position)));
					tokens.push(new Token(TokenKind.Integer, text(start, position), file.span(start, position)));
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
				tokens.push(new Token(kind, text(start, position), file.span(start, position)));
				continue;
			}
			if (code >= 0x80) {
				var end = position + utf8Width(code);
				if (end > source.length)
					end = source.length;
				throw new CompileError(new Diagnostic("E0001", 'Unexpected character "${text(position, end)}"', file.span(position, end)));
			}
			position++;
			var character = String.fromCharCode(code);
			var kind = switch character {
				case "(": TokenKind.LeftParen;
				case ")": TokenKind.RightParen;
				case "{": TokenKind.LeftBrace;
				case "}": TokenKind.RightBrace;
				case ":": TokenKind.Colon;
				case ";": TokenKind.Semicolon;
				case ",": TokenKind.Comma;
				case ".": TokenKind.Dot;
				case "=":
					if (position < source.length && source.get(position) == "=".code) {
						position++;
						TokenKind.EqualEqual;
					} else TokenKind.Assign;
				case "<":
					if (position < source.length && source.get(position) == "=".code) {
						position++;
						TokenKind.LessEqual;
					} else TokenKind.Less;
				case ">":
					if (position < source.length && source.get(position) == "=".code) {
						position++;
						TokenKind.GreaterEqual;
					} else TokenKind.Greater;
				case "!":
					if (position < source.length && source.get(position) == "=".code) {
						position++;
						TokenKind.NotEqual;
					} else TokenKind.Not;
				case "&":
					if (position < source.length && source.get(position) == "&".code) {
						position++;
						TokenKind.AndAnd;
					} else TokenKind.Ampersand;
				case "|":
					if (position < source.length && source.get(position) == "|".code) {
						position++;
						TokenKind.OrOr;
					} else TokenKind.Pipe;
				case "^": TokenKind.Caret;
				case "[": TokenKind.LeftBracket;
				case "]": TokenKind.RightBracket;
				case "?": TokenKind.Question;
				case "@": TokenKind.At;
				case "+":
					if (position < source.length && source.get(position) == "=".code) {
						position++;
						TokenKind.PlusAssign;
					} else if (position < source.length && source.get(position) == "+".code) {
						position++;
						TokenKind.Increment;
					} else TokenKind.Plus;
				case "-":
					if (position < source.length && source.get(position) == ">".code) {
						position++;
						TokenKind.Arrow;
					} else if (position < source.length && source.get(position) == "=".code) {
						position++;
						TokenKind.MinusAssign;
					} else if (position < source.length && source.get(position) == "-".code) {
						position++;
						TokenKind.Decrement;
					} else TokenKind.Minus;
				case "*": TokenKind.Star;
				case "/": TokenKind.Slash;
				case "%": TokenKind.Percent;
				default: throw new CompileError(new Diagnostic("E0001", 'Unexpected character "${String.fromCharCode(code)}"', file.span(start, position)));
			}
			tokens.push(new Token(kind, text(start, position), file.span(start, position)));
		}
		tokens.push(new Token(TokenKind.Eof, "", file.span(position, position)));
		return tokens;
	}

	inline function text(start:Int, end:Int):String
		return source.getString(start, end - start);

	static inline function utf8Width(code:Int):Int
		return code < 0xE0 ? 2 : code < 0xF0 ? 3 : 4;

	static function keyword(text:String):TokenKind {
		return switch text {
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
		}
	}

	static inline function isWhitespace(code:Int):Bool
		return code == " ".code || code == "\t".code || code == "\n".code || code == "\r".code;

	static inline function isDigit(code:Int):Bool
		return code >= "0".code && code <= "9".code;

	static inline function isIdentifierStart(code:Int):Bool
		return (code >= "A".code && code <= "Z".code) || (code >= "a".code && code <= "z".code) || code == "_".code;

	static inline function isIdentifierPart(code:Int):Bool
		return isIdentifierStart(code) || isDigit(code);

	static inline function isHexDigit(code:Int):Bool
		return isDigit(code) || code >= "A".code && code <= "F".code || code >= "a".code && code <= "f".code;
}
