package compiler.syntax;

import compiler.core.Source.SourceFile;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Token.TokenKind;

/** A token of a `TokenTable`: its row, counted from the file's first token. */
abstract TokenId(Int) {
	inline function new(row:Int)
		this = row;

	public static inline function ofRow(row:Int):TokenId
		return new TokenId(row);

	public var row(get, never):Int;

	inline function get_row():Int
		return this;
}

/**
 * The tokens of one file as columns, indexed by `TokenId` (`TOKEN_TABLE.md`). A table never changes once made. A token's
 * span is made when it is asked for, as most spans the parser reads only bound a larger one; a table made from tokens gives
 * back their spans.
 *
 * `>=` is two rows, `>` then `=` with no space between: a type may end right before an initializer (`Array<T>=[]`), so the
 * grammar reads them apart and expressions join them back, as they do `>>`. As tokens (`toTokens`), they are one again.
 */
class TokenTable {
	@:processWide("a table with no tokens, never changed: what a module holds once its tokens are released")
	public static final empty = new TokenTable(null, [], [], [], []);

	/** The file of the tokens; null only for a table with none. */
	final source:Null<SourceFile>;

	final kinds:Array<TokenKind>;
	final texts:Array<String>;
	final starts:Array<Int>;
	final ends:Array<Int>;

	/** Per row, the span of the token it was made from; null for a lexed table. */
	final spans:Null<Array<SourceSpan>>;

	public function new(source:Null<SourceFile>, kinds:Array<TokenKind>, texts:Array<String>, starts:Array<Int>,
			ends:Array<Int>, ?spans:Array<SourceSpan>) {
		this.source = source;
		this.kinds = kinds;
		this.texts = texts;
		this.starts = starts;
		this.ends = ends;
		this.spans = spans;
	}

	/** The table of tokens a caller already has, a `>=` split as the table keeps it. */
	public static function ofTokens(tokens:Array<Token>):TokenTable {
		var kinds = [], texts = [], starts = [], ends = [], spans:Array<SourceSpan> = [];
		for (token in tokens) {
			var span = token.span;
			if (token.kind == TokenKind.GreaterEqual) {
				kinds.push(TokenKind.Greater);
				texts.push(">");
				starts.push(span.start);
				ends.push(span.start + 1);
				spans.push(new SourceSpan(span.file, span.start, span.start + 1));
				kinds.push(TokenKind.Assign);
				texts.push("=");
				starts.push(span.start + 1);
				ends.push(span.end);
				spans.push(new SourceSpan(span.file, span.start + 1, span.end));
				continue;
			}
			kinds.push(token.kind);
			texts.push(token.text);
			starts.push(span.start);
			ends.push(span.end);
			spans.push(span);
		}
		return new TokenTable(tokens.length == 0 ? null : tokens[0].span.file, kinds, texts, starts, ends, spans);
	}

	public var length(get, never):Int;

	inline function get_length():Int
		return kinds.length;

	/** The tokens' ids, in source order. */
	public inline function iterator():TokenIds
		return new TokenIds(kinds.length);

	public inline function kind(id:TokenId):TokenKind
		return kinds[id.row];

	public inline function text(id:TokenId):String
		return texts[id.row];

	public inline function start(id:TokenId):Int
		return starts[id.row];

	public inline function end(id:TokenId):Int
		return ends[id.row];

	public function span(id:TokenId):SourceSpan {
		var known = spans;
		return known != null ? known[id.row] : new SourceSpan(file, starts[id.row], ends[id.row]);
	}

	public var file(get, never):SourceFile;

	function get_file():SourceFile {
		var file = source;
		if (file == null)
			throw new compiler.core.InternalError("A token table with no tokens has no file");
		return file;
	}

	/** Token `id` as an object, for a caller that keeps tokens. */
	public function token(id:TokenId):Token
		return new Token(kind(id), text(id), span(id));

	/** Whether `id` is the `>` of a `>=`, which a token keeps whole. */
	public function startsGreaterEqual(id:TokenId):Bool {
		var row = id.row;
		return kinds[row] == TokenKind.Greater && row + 1 < kinds.length && kinds[row + 1] == TokenKind.Assign
			&& ends[row] == starts[row + 1];
	}

	/** The tokens as the lexer spells them, a `>=` whole. */
	public function toTokens():Array<Token> {
		var tokens = [], row = 0;
		while (row < kinds.length) {
			var id = TokenId.ofRow(row);
			if (startsGreaterEqual(id)) {
				tokens.push(new Token(TokenKind.GreaterEqual, ">=", new SourceSpan(file, starts[row], ends[row + 1])));
				row += 2;
				continue;
			}
			tokens.push(token(id));
			row++;
		}
		return tokens;
	}

	/** The same tokens placed `offset` bytes on in `target`: an embedded expression's tokens at their place in its file. */
	public function moved(target:SourceFile, offset:Int):TokenTable
		return new TokenTable(target, kinds, texts, [for (start in starts) start + offset],
			[for (end in ends) end + offset]);
}

/** Iterates a table's ids in source order. */
class TokenIds {
	var row = 0;
	final length:Int;

	public inline function new(length:Int)
		this.length = length;

	public inline function hasNext():Bool
		return row < length;

	public inline function next():TokenId
		return TokenId.ofRow(row++);
}
