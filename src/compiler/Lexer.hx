package compiler;

import compiler.Token.TokenKind;
import compiler.Source.SourceFile;
import compiler.Diagnostic.CompileError;

class Lexer {
	final file:SourceFile;
	final source:String;
	var position:Int = 0;

	public function new(file:SourceFile) {
		this.file = file;
		this.source = file.text;
	}

	public function tokenize():Array<Token> {
		var tokens = [];
		while (position < source.length) {
			var code = source.charCodeAt(position);
			if (isWhitespace(code)) {
				position++;
				continue;
			}
			if (code == 47 && position + 1 < source.length) {
				var next = source.charCodeAt(position + 1);
				if (next == 47) {
					position += 2;
					while (position < source.length && source.charCodeAt(position) != 10)
						position++;
					continue;
				}
				if (next == 42) {
					var commentStart = position;
					position += 2;
					while (position + 1 < source.length && !(source.charCodeAt(position) == 42 && source.charCodeAt(position + 1) == 47))
						position++;
					if (position + 1 >= source.length)
						throw new CompileError(new Diagnostic("E0001", "Unterminated block comment", file.span(commentStart, position)));
					position += 2;
					continue;
				}
			}
			var start = position;
			if (code == 34 || code == 39) {
				var quote = code;
				position++;
				var escaped = false, closed = false;
				while (position < source.length) {
					var current = source.charCodeAt(position++);
					if (escaped) {
						escaped = false;
						continue;
					}
					if (current == 92) {
						escaped = true;
						continue;
					}
					if (current == quote) {
						closed = true;
						break;
					}
				}
				if (!closed)
					throw new CompileError(new Diagnostic("E0001", "Unterminated string literal", file.span(start, position)));
				tokens.push(new Token(TokenKind.StringLiteral, source.substring(start, position), file.span(start, position)));
				continue;
			}
			if (isIdentifierStart(code)) {
				position++;
				while (position < source.length && isIdentifierPart(source.charCodeAt(position)))
					position++;
				var text = source.substring(start, position);
				tokens.push(new Token(keyword(text), text, file.span(start, position)));
				continue;
			}
			if (isDigit(code)) {
				position++;
				if (code == 48 && position < source.length && (source.charAt(position) == "x" || source.charAt(position) == "X")) {
					position++;
					var digitsStart = position;
					while (position < source.length && isHexDigit(source.charCodeAt(position)))
						position++;
					if (position == digitsStart)
						throw new CompileError(new Diagnostic("E0001", "Hexadecimal literal requires at least one digit", file.span(start, position)));
					tokens.push(new Token(TokenKind.Integer, source.substring(start, position), file.span(start, position)));
					continue;
				}
				while (position < source.length && isDigit(source.charCodeAt(position)))
					position++;
				var kind = TokenKind.Integer;
				if (position + 1 < source.length && source.charAt(position) == "." && isDigit(source.charCodeAt(position + 1))) {
					kind = TokenKind.Float;
					position++;
					while (position < source.length && isDigit(source.charCodeAt(position)))
						position++;
				}
				tokens.push(new Token(kind, source.substring(start, position), file.span(start, position)));
				continue;
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
					if (position < source.length && source.charAt(position) == "=") {
						position++;
						TokenKind.EqualEqual;
					} else TokenKind.Assign;
				case "<":
					if (position < source.length && source.charAt(position) == "=") {
						position++;
						TokenKind.LessEqual;
					} else TokenKind.Less;
				case ">":
					if (position < source.length && source.charAt(position) == "=") {
						position++;
						TokenKind.GreaterEqual;
					} else TokenKind.Greater;
				case "!":
					if (position < source.length && source.charAt(position) == "=") {
						position++;
						TokenKind.NotEqual;
					} else TokenKind.Not;
				case "&":
					if (position < source.length && source.charAt(position) == "&") {
						position++;
						TokenKind.AndAnd;
					} else TokenKind.Ampersand;
				case "|":
					if (position < source.length && source.charAt(position) == "|") {
						position++;
						TokenKind.OrOr;
					} else TokenKind.Pipe;
				case "^": TokenKind.Caret;
				case "[": TokenKind.LeftBracket;
				case "]": TokenKind.RightBracket;
				case "?": TokenKind.Question;
				case "@": TokenKind.At;
				case "+":
					if (position < source.length && source.charAt(position) == "=") {
						position++;
						TokenKind.PlusAssign;
					} else if (position < source.length && source.charAt(position) == "+") {
						position++;
						TokenKind.Increment;
					} else TokenKind.Plus;
				case "-":
					if (position < source.length && source.charAt(position) == ">") {
						position++;
						TokenKind.Arrow;
					} else if (position < source.length && source.charAt(position) == "=") {
						position++;
						TokenKind.MinusAssign;
					} else if (position < source.length && source.charAt(position) == "-") {
						position++;
						TokenKind.Decrement;
					} else TokenKind.Minus;
				case "*": TokenKind.Star;
				case "/": TokenKind.Slash;
				case "%": TokenKind.Percent;
				default: throw new CompileError(new Diagnostic("E0001", 'Unexpected character "${String.fromCharCode(code)}"', file.span(start, position)));
			}
			tokens.push(new Token(kind, source.substring(start, position), file.span(start, position)));
		}
		tokens.push(new Token(TokenKind.Eof, "", file.span(position, position)));
		return tokens;
	}

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
		return code == 32 || code == 9 || code == 10 || code == 13;

	static inline function isDigit(code:Int):Bool
		return code >= 48 && code <= 57;

	static inline function isIdentifierStart(code:Int):Bool
		return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95;

	static inline function isIdentifierPart(code:Int):Bool
		return isIdentifierStart(code) || isDigit(code);

	static inline function isHexDigit(code:Int):Bool
		return isDigit(code) || code >= 65 && code <= 70 || code >= 97 && code <= 102;
}
