package compiler.service;

import compiler.core.Source.SourceFile;
import compiler.syntax.AstPredicates;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.Token.TokenKind;
import compiler.syntax.TokenTable;

/** A lambda written `function(...) body` that an arrow can write: it declares no return type and no rest parameter. */
typedef FunctionLambda = {
	/** Where `function` starts, which is where the typer's span of the lambda starts. */
	final start:Int;

	/** Where the body starts, after a `return` that an expression body may open with. */
	final bodyStart:Int;

	/** What replaces `start...bodyStart`: `x -> ` or `(a, b) -> `. */
	final arrowHead:String;

	/**
	 * Whether the arrow means the same by its syntax alone: the body is an expression, or a block that does not end in an
	 * expression. A block that does would return that expression's value as an arrow, where the `function` drops it, so only the
	 * lambda's types can show the two agree: a type that returns Void drops it either way, and a Void value is nothing to return
	 * (`TypedProgram.lambdaTrailingValues`).
	 */
	final proven:Bool;
}

/**
 * Finds the lambdas written with `function` that an arrow can write instead, as `haxeon lint` asks (rule `function-lambda`): one
 * form for a lambda. A lambda with a return type (`function(x):Int ...`) or a rest parameter keeps the `function` form, which is
 * the only one that can say either. A named local function is a declaration, not a lambda, and is left alone.
 */
class FunctionLambdas {
	/** The lambdas of `source`, read through its conditional directives (offsets preserved), so a file with `#if` is read too. */
	public static function find(path:String, source:String):Array<FunctionLambda> {
		var file = new SourceFile(path, ConditionalCompilation.process(new SourceFile(path, source), []).text);
		var tokens = TokenTable.ofTokens(new Lexer(file).tokenize()), found:Array<FunctionLambda> = [];
		for (index in 0...tokens.length - 1)
			if (kindAt(tokens, index) == TokenKind.Function && kindAt(tokens, index + 1) == TokenKind.LeftParen) {
				var lambda = at(file, tokens, index);
				if (lambda != null)
					found.push(lambda);
			}
		return found;
	}

	/** Writes `lambda` as an arrow. */
	public static function convert(edits:SourceEdits, lambda:FunctionLambda):Void
		edits.replace(lambda.start, lambda.bodyStart, lambda.arrowHead);

	static function at(file:SourceFile, tokens:TokenTable, index:Int):Null<FunctionLambda> {
		var close = matching(tokens, index + 1);
		if (close < 0 || close + 1 >= tokens.length || kindAt(tokens, close + 1) == TokenKind.Colon)
			return null;
		for (inside in index + 2...close)
			if (kindAt(tokens, inside) == TokenKind.Dot && kindAt(tokens, inside + 1) == TokenKind.Dot
				&& kindAt(tokens, inside + 2) == TokenKind.Dot)
				return null;
		var body = close + 1;
		if (kindAt(tokens, body) == TokenKind.Return)
			switch kindAt(tokens, ++body) {
				case TokenKind.Semicolon | TokenKind.RightBrace | TokenKind.RightParen | TokenKind.Comma
					| TokenKind.Eof:
					return null;
				default:
			}
		var bodyKind = kindAt(tokens, body), proven = true;
		if (bodyKind == TokenKind.LeftBrace) {
			// An arrow reads `{name: ...}` as an object literal, where a `function` reads a block.
			var first = kindAt(tokens, body + 1);
			if ((first == TokenKind.Identifier || first == TokenKind.StringLiteral)
				&& kindAt(tokens, body + 2) == TokenKind.Colon)
				return null;
			var end = matching(tokens, body);
			if (end < 0)
				return null;
			proven = !endsInExpression(file, offset(tokens, body), tokens.end(TokenId.ofRow(end)));
		}
		var arguments = close == index + 2 ? "" : file.slice(offset(tokens, index + 2),
			tokens.end(TokenId.ofRow(close - 1)));
		return {
			start: offset(tokens, index),
			bodyStart: offset(tokens, body),
			arrowHead: (close == index + 3
				&& kindAt(tokens, index + 2) == TokenKind.Identifier ? arguments : '($arguments)') + " -> ",
			proven: proven
		};
	}

	/** Whether the block at `start...end` ends in an expression, or cannot be read on its own; parsed as a method's body. */
	static function endsInExpression(file:SourceFile, start:Int, end:Int):Bool {
		var wrapped = new SourceFile(file.path, "class L { static function f() " + file.slice(start, end) + " }");
		return try AstPredicates.endsInExpression(new Parser(new Lexer(wrapped).tokenize()).parseProgram().classes[0]
			.methods[0].statements)
			catch (_:Dynamic) true;
	}

	/** The row of the bracket that closes the one at `open`, or -1. */
	static function matching(tokens:TokenTable, open:Int):Int {
		var depth = 0;
		for (index in open...tokens.length)
			switch kindAt(tokens, index) {
				case TokenKind.LeftParen | TokenKind.LeftBrace | TokenKind.LeftBracket:
					depth++;
				case TokenKind.RightParen | TokenKind.RightBrace | TokenKind.RightBracket:
					if (--depth == 0)
						return index;
				default:
			}
		return -1;
	}

	static inline function offset(tokens:TokenTable, index:Int):Int
		return tokens.start(TokenId.ofRow(index));

	static inline function kindAt(tokens:TokenTable, index:Int):TokenKind
		return index < tokens.length ? tokens.kind(TokenId.ofRow(index)) : TokenKind.Eof;
}
