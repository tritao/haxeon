package compiler.semantic;

import compiler.service.CancellationToken;
import compiler.syntax.Token;
import compiler.syntax.Token.TokenKind;

/** Token-only completion context classification shared by semantic queries. */
class CompletionContextSyntax {
	public static function isTypeContext(tokens:Array<Token>, position:Int, ?cancellation:CancellationToken):Bool {
		var previous:Null<Token> = null, previousIndex = -1;
		for (lexical in tokens) {
			if (cancellation != null)
				cancellation.check();
			if (lexical.kind == TokenKind.Eof)
				break;
			if (lexical.span.end > position)
				break;
			previous = lexical;
			previousIndex++;
		}
		if (previous == null)
			return false;
		return switch previous.kind {
			case TokenKind.Colon: isTypeColon(tokens, previousIndex, cancellation);
			case TokenKind.Extends, TokenKind.Implements, TokenKind.New: true;
			case TokenKind.Identifier, TokenKind.Comma: isTypeNameContext(tokens, previousIndex, cancellation);
			case TokenKind.Less: isGenericTypeContext(tokens, previousIndex, cancellation);
			default: false;
		};
	}

	static function isTypeColon(tokens:Array<Token>, index:Int, ?cancellation:CancellationToken):Bool {
		var cursor = index - 1;
		while (cursor >= 0) {
			if (cancellation != null)
				cancellation.check();
			switch tokens[cursor].kind {
				case TokenKind.Function, TokenKind.Var, TokenKind.For, TokenKind.Catch:
					return true;
				case TokenKind.Question, TokenKind.Case, TokenKind.Semicolon, TokenKind.LeftBrace, TokenKind.RightBrace, TokenKind.Assign,
					TokenKind.Return, TokenKind.Arrow:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	static function isTypeNameContext(tokens:Array<Token>, index:Int, ?cancellation:CancellationToken):Bool {
		var cursor = index - 1;
		while (cursor >= 0) {
			if (cancellation != null)
				cancellation.check();
			switch tokens[cursor].kind {
				case TokenKind.Colon:
					return isTypeColon(tokens, cursor, cancellation);
				case TokenKind.Extends, TokenKind.Implements, TokenKind.New:
					return true;
				case TokenKind.Semicolon, TokenKind.LeftBrace, TokenKind.RightBrace, TokenKind.Assign, TokenKind.Return:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	static function isGenericTypeContext(tokens:Array<Token>, index:Int, ?cancellation:CancellationToken):Bool {
		var cursor = index, depth = 0;
		while (cursor >= 0) {
			if (cancellation != null)
				cancellation.check();
			switch tokens[cursor].kind {
				case TokenKind.Greater:
					depth++;
				case TokenKind.Less:
					if (depth == 0)
						return isTypeNameContext(tokens, cursor, cancellation);
					depth--;
				case TokenKind.Semicolon, TokenKind.LeftBrace, TokenKind.RightBrace, TokenKind.Assign, TokenKind.Return:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	public static function isImportContext(tokens:Array<Token>, position:Int, ?cancellation:CancellationToken):Bool {
		var previous:Null<Token> = null, previousIndex = -1;
		for (index in 0...tokens.length) {
			if (cancellation != null)
				cancellation.check();
			if (tokens[index].kind == TokenKind.Eof || tokens[index].span.end > position)
				break;
			previous = tokens[index];
			previousIndex = index;
		}
		if (previous == null)
			return false;
		if (previous.kind == TokenKind.Import)
			return true;
		if (previous.kind != TokenKind.Identifier && previous.kind != TokenKind.Dot)
			return false;
		var index = previousIndex - 1;
		while (index >= 0) {
			if (cancellation != null)
				cancellation.check();
			var kind = tokens[index].kind;
			if (kind == TokenKind.Import)
				return true;
			if (kind == TokenKind.Semicolon || kind == TokenKind.LeftBrace || kind == TokenKind.RightBrace)
				return false;
			index--;
		}
		return false;
	}

	public static function isObjectFieldContext(tokens:Array<Token>, position:Int, ?cancellation:CancellationToken):Bool {
		var previous:Null<Token> = null;
		for (token in tokens) {
			if (cancellation != null)
				cancellation.check();
			if (token.kind == TokenKind.Eof || token.span.end > position)
				break;
			previous = token;
		}
		if (previous == null || previous.kind != TokenKind.Colon)
			return false;
		var depth = 0;
		var index = tokens.length - 1;
		while (index >= 0) {
			if (cancellation != null)
				cancellation.check();
			var token = tokens[index];
			if (token.span.start >= position) {
				index--;
				continue;
			}
			switch token.kind {
				case TokenKind.RightBrace:
					depth++;
				case TokenKind.LeftBrace:
					if (depth == 0)
						return true;
					depth--;
				default:
			}
			index--;
		}
		return false;
	}

	public static function isPatternContext(tokens:Array<Token>, position:Int, ?cancellation:CancellationToken):Bool {
		var index = lastTokenBefore(tokens, position);
		while (index >= 0) {
			if (cancellation != null)
				cancellation.check();
			var kind = tokens[index].kind;
			if (kind == TokenKind.Case)
				return true;
			if (kind == TokenKind.Colon || kind == TokenKind.Semicolon || kind == TokenKind.LeftBrace || kind == TokenKind.RightBrace)
				return false;
			index--;
		}
		return false;
	}

	public static function isOverrideContext(tokens:Array<Token>, position:Int, ?cancellation:CancellationToken):Bool {
		var index = lastTokenBefore(tokens, position);
		if (cancellation != null)
			cancellation.check();
		return index >= 0 && tokens[index].kind == TokenKind.Identifier && tokens[index].text == "override";
	}

	static function lastTokenBefore(tokens:Array<Token>, position:Int):Int {
		var result = -1;
		for (index in 0...tokens.length) {
			if (tokens[index].kind == TokenKind.Eof || tokens[index].span.end > position)
				break;
			result = index;
		}
		return result;
	}
}
