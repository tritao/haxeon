package compiler.service;

import compiler.syntax.Token.TokenKind;
import compiler.syntax.TokenTable;

/** A named argument that passes the variable of its own name, `enabled: enabled`, which `enabled:` says. */
typedef RedundantArgumentName = {
	final name:String;

	/** The offset of the argument's name, where it is reported. */
	final start:Int;

	/** The UTF-8 byte offsets to remove for the short form: from the end of the colon to the end of the repeated name. */
	final removeStart:Int;

	final removeEnd:Int;
}

/**
 * Finds call arguments written `name: name`. The short form `name:` passes the same variable (NAMED_ARGUMENTS.md), so a name
 * the call repeats says nothing a reader needs. Only an argument that is that and nothing more counts: `name: name.field` or
 * `name: name + 1` passes something else. Parentheses are tracked, so an object literal's `{name: name}` is not an argument.
 */
class RedundantArgumentNames {
	public static function find(tokens:TokenTable):Array<RedundantArgumentName> {
		var found:Array<RedundantArgumentName> = [], open:Array<TokenKind> = [];
		for (index in 0...tokens.length) {
			var kind = kindAt(tokens, index);
			switch kind {
				case TokenKind.LeftParen | TokenKind.LeftBrace | TokenKind.LeftBracket:
					open.push(kind);
				case TokenKind.RightParen | TokenKind.RightBrace | TokenKind.RightBracket:
					open.pop();
				case TokenKind.Identifier if (open.length > 0 && open[open.length - 1] == TokenKind.LeftParen
					&& index > 0 && index + 3 < tokens.length):
					var before = kindAt(tokens, index - 1), after = kindAt(tokens, index + 3);
					if ((before == TokenKind.LeftParen || before == TokenKind.Comma)
						&& kindAt(tokens, index + 1) == TokenKind.Colon
						&& kindAt(tokens, index + 2) == TokenKind.Identifier
						&& (after == TokenKind.Comma || after == TokenKind.RightParen)) {
						var name = tokens.text(TokenId.ofRow(index));
						if (tokens.text(TokenId.ofRow(index + 2)) == name)
							found.push({
								name: name,
								start: tokens.start(TokenId.ofRow(index)),
								removeStart: tokens.end(TokenId.ofRow(index + 1)),
								removeEnd: tokens.end(TokenId.ofRow(index + 2))
							});
					}
				default:
			}
		}
		return found;
	}

	/** `source` with each of `found` in its short form. Token offsets count UTF-8 bytes, so the cuts are made in its bytes. */
	public static function shorten(source:String, found:Array<RedundantArgumentName>):String {
		if (found.length == 0)
			return source;
		var ordered = found.copy();
		ordered.sort((left, right) -> left.removeStart - right.removeStart);
		var bytes = haxe.io.Bytes.ofString(source), result = new haxe.io.BytesBuffer(), position = 0;
		for (item in ordered) {
			result.addBytes(bytes, position, item.removeStart - position);
			position = item.removeEnd;
		}
		result.addBytes(bytes, position, bytes.length - position);
		return result.getBytes().toString();
	}

	static inline function kindAt(tokens:TokenTable, index:Int):TokenKind
		return tokens.kind(TokenId.ofRow(index));
}
