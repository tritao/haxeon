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
			var start = position;
			if (code == 34) {
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
					if (current == 34) {
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
				case ">": TokenKind.Greater;
				case "[": TokenKind.LeftBracket;
				case "]": TokenKind.RightBracket;
				case "+":
					if (position < source.length && source.charAt(position) == "=") {
						position++;
						TokenKind.PlusAssign;
					} else TokenKind.Plus;
				case "-":
					if (position < source.length && source.charAt(position) == ">") {
						position++;
						TokenKind.Arrow;
					} else if (position < source.length && source.charAt(position) == "=") {
						position++;
						TokenKind.MinusAssign;
					} else TokenKind.Minus;
				case "*": TokenKind.Star;
				case "/": TokenKind.Slash;
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
			case "final": TokenKind.Final;
			case "new": TokenKind.New;
			case "this": TokenKind.This;
			case "Void": TokenKind.Void;
			case "function": TokenKind.Function;
			case "var": TokenKind.Var;
			case "return": TokenKind.Return;
			case "if": TokenKind.If;
			case "else": TokenKind.Else;
			case "while": TokenKind.While;
			case "for": TokenKind.For;
			case "in": TokenKind.In;
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
}
