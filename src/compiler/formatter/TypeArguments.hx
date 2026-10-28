package compiler.formatter;

import compiler.syntax.Token.TokenKind;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;

/** Matched `<` and `>` token indexes of every type argument list in a token array. */
typedef TypeArgumentPairs = {
	final opens:Map<Int, Int>;
	final closes:Map<Int, Int>;
	/** Indexes of `>=` tokens that really close a list and start an assignment: `Array<Int>= []`. */
	final splits:Array<Int>;
}

/**
	Tells type argument lists (`Map<String, Array<Int>>`) from comparison and shift operators.

	The lexer emits `<` and `>` as single characters, so the formatter has to decide which ones bracket
	types. An angle bracket opens a list when it follows a type name and the tokens up to its matching
	`>` can only be a type: names, dots, commas, nested lists, and anonymous structure or function types
	(`{a:Int}`, `(Int) -> Void`). Anything else in between, such as a literal, an operator or a `;`,
	means a comparison. The outermost list must also be followed by a token that can follow a type.
**/
class TypeArguments {
	public static function find(tokens:Array<FormatToken>):TypeArgumentPairs {
		var opens:Map<Int, Int> = [], closes:Map<Int, Int> = [], splits:Array<Int> = [], syntax:Array<Int> = [];
		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index]))
				syntax.push(index);
		for (position in 0...syntax.length)
			if (kindAt(tokens, syntax, position) == TokenKind.Less
				&& !opens.exists(syntax[position])
				&& isTypeName(position == 0 ? null : kindAt(tokens, syntax, position - 1)))
				scan(tokens, syntax, position, opens, closes, splits);
		return {opens: opens, closes: closes, splits: splits};
	}

	static function scan(tokens:Array<FormatToken>, syntax:Array<Int>, start:Int, opens:Map<Int, Int>, closes:Map<Int, Int>, splits:Array<Int>):Void {
		var open:Array<Int> = [], hasContent:Array<Bool> = [], found:Array<{open:Int, close:Int}> = [], groups = 0;
		for (position in start...syntax.length) {
			var kind = kindAt(tokens, syntax, position);
			switch kind {
				case TokenKind.Less:
					if (!isTypeName(kindAt(tokens, syntax, position - 1)))
						return;
					open.push(position);
					hasContent.push(false);
				case TokenKind.Greater, TokenKind.GreaterEqual:
					var combined = kind == TokenKind.GreaterEqual;
					if (open.length == 0 || (combined && open.length > 1))
						return;
					var opener = open.pop();
					if (!hasContent.pop())
						return;
					found.push({open: syntax[opener], close: syntax[position]});
					if (open.length > 0)
						hasContent[hasContent.length - 1] = true;
					else {
						var after = position + 1 < syntax.length ? kindAt(tokens, syntax, position + 1) : null;
						if (!combined && !mayFollowType(after))
							return;
						if (combined)
							splits.push(syntax[position]);
						for (pair in found) {
							opens.set(pair.open, pair.close);
							closes.set(pair.close, pair.open);
						}
						return;
					}
				case TokenKind.Identifier, TokenKind.TypeInt, TokenKind.TypeBool, TokenKind.TypeFloat, TokenKind.TypeString, TokenKind.Void,
					TokenKind.Comma, TokenKind.Dot:
					hasContent[hasContent.length - 1] = true;
				case TokenKind.Question, TokenKind.Colon:
					// Only inside a structure or function type: `{?a:Int}`, `(?Int) -> Void`.
					if (groups == 0)
						return;
				case TokenKind.LeftParen, TokenKind.LeftBrace:
					groups++;
				case TokenKind.RightParen, TokenKind.RightBrace:
					if (groups == 0)
						return;
					groups--;
				case TokenKind.Arrow, TokenKind.Ampersand, TokenKind.LeftBracket, TokenKind.RightBracket:
				default:
					return;
			}
		}
	}

	static function kindAt(tokens:Array<FormatToken>, syntax:Array<Int>, position:Int):Null<TokenKind>
		return FormatTokenTools.syntaxKind(tokens[syntax[position]]);

	static function isTypeName(kind:Null<TokenKind>):Bool
		return kind == TokenKind.Identifier || kind == TokenKind.TypeInt || kind == TokenKind.TypeBool || kind == TokenKind.TypeFloat
			|| kind == TokenKind.TypeString || kind == TokenKind.Void;

	static function mayFollowType(kind:Null<TokenKind>):Bool
		return kind == null || kind == TokenKind.LeftParen || kind == TokenKind.LeftBracket || kind == TokenKind.LeftBrace || kind == TokenKind.Dot
			|| kind == TokenKind.Comma || kind == TokenKind.RightParen || kind == TokenKind.RightBracket || kind == TokenKind.RightBrace
			|| kind == TokenKind.Assign || kind == TokenKind.Colon || kind == TokenKind.Semicolon || kind == TokenKind.Arrow || kind == TokenKind.Return
			|| kind == TokenKind.Extends || kind == TokenKind.Implements;

	/** Splits each `>=` that closes a type argument list into `>` and `=`, so both are spaced as ordinary tokens. */
	public static function splitAssignments(tokens:Array<FormatToken>):Array<FormatToken> {
		var splits = find(tokens).splits;
		if (splits.length == 0)
			return tokens;
		var result:Array<FormatToken> = [];
		for (index in 0...tokens.length) {
			var token = tokens[index];
			if (splits.indexOf(index) < 0) {
				result.push(token);
				continue;
			}
			result.push({kind: FormatTokenKind.Syntax(TokenKind.Greater), text: ">", start: token.start, end: token.start + 1});
			result.push({kind: FormatTokenKind.Syntax(TokenKind.Assign), text: "=", start: token.start + 1, end: token.end});
		}
		return result;
	}
}
