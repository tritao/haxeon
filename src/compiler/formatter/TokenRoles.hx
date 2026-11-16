package compiler.formatter;

import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;
import compiler.syntax.Token.TokenKind;

/** The bracket structure the annotator found, which the roles are derived from. */
typedef TokenStructure = {
	final matching:Map<Int, Int>;
	final blockOpens:Map<Int, Bool>;
	final typeArgumentOpens:Map<Int, Bool>;
	final typeArgumentCloses:Map<Int, Bool>;
}

/**
 * What each token is, decided once for the whole file and keyed by the token's source offset, so every stage asks the same question
 * the same way: the line builder (which works with the file's tokens) and the break analyzer (which works with one logical line's) no
 * longer re-derive structure from their own slices of the token list, with their own indices.
 *
 * Every role reads the file, never a line: a walk back stops where the code it asks about ends (an unmatched bracket, a `;`, a `,`), not
 * where a logical line happens to begin.
 */
class TokenRoles {
	/** Bracket offset -> the offset of the bracket that matches it: `(`, `[`, `{` and type argument `<` / `>`. */
	public final partner = new Map<Int, Int>();

	/** The `)` of an `if`, `for`, `while` or `catch` header, after which a body begins. */
	public final controlHeaderCloses = new Map<Int, Bool>();

	/** The `}` of a `do` block, after which its `while` belongs to the same statement. */
	public final doBlockCloses = new Map<Int, Bool>();

	/** The `(` of a function's parameters: `function name(`, `function new(`, `function name<T>(`, `function(`. */
	public final parameterOpens = new Map<Int, Bool>();

	/** The `:` that ends a `case ...:` or `default:` header. */
	public final caseColons = new Map<Int, Bool>();

	/** The `?` of a conditional expression (not of an optional parameter or field). */
	public final ternaryQuestions = new Map<Int, Bool>();

	/** The `:` of a conditional expression, paired with its `?`. */
	public final ternaryColons = new Map<Int, Bool>();

	/** A `:` written with a space after it: a case header's, an object field's, a conditional's. A type annotation's is not. */
	public final spacedColons = new Map<Int, Bool>();

	/** The `->` of an old-style function type, written tight (`Int->Void`); a lambda's and a new-style type's are spaced. */
	public final tightArrows = new Map<Int, Bool>();

	/** The last token of a metadata expression: `@:keep`, `@name`, `@:native("x")`. */
	public final metadataEnds = new Map<Int, Bool>();

	/** A `+` or `-` that is a sign, not an addition: `-1`, `(-x)`, `for (...) -1`. */
	public final unarySigns = new Map<Int, Bool>();

	final tokens:Array<FormatToken>;
	final syntax:TokenStructure;

	/** Indices of the code tokens, and each code token's position among them. */
	final code:Array<Int> = [];

	final position = new Map<Int, Int>();

	public static function compute(tokens:Array<FormatToken>, syntax:TokenStructure):TokenRoles
		return new TokenRoles(tokens, syntax);

	function new(tokens:Array<FormatToken>, syntax:TokenStructure) {
		this.tokens = tokens;
		this.syntax = syntax;
		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index])) {
				position.set(index, code.length);
				code.push(index);
			}
		for (index => other in syntax.matching)
			partner.set(tokens[index].start, tokens[other].start);
		for (step in 0...code.length) {
			var index = code[step], token = tokens[index];
			switch kind(step) {
				case TokenKind.RightParen:
					if (keywordBefore(step, [TokenKind.If, TokenKind.For, TokenKind.While, TokenKind.Catch]))
						controlHeaderCloses.set(token.start, true);
				case TokenKind.RightBrace:
					if (keywordBefore(step, [TokenKind.Do]))
						doBlockCloses.set(token.start, true);
				case TokenKind.LeftParen:
					if (opensParameters(step))
						parameterOpens.set(token.start, true);
				case TokenKind.Question:
					if (isTernaryQuestion(index))
						ternaryQuestions.set(token.start, true);
				case TokenKind.Plus | TokenKind.Minus:
					if (isUnary(index))
						unarySigns.set(token.start, true);
				default:
			}
			if (endsMetadata(step))
				metadataEnds.set(token.start, true);
		}
		// Colons need the questions; arrows need the colons.
		for (step in 0...code.length)
			if (kind(step) == TokenKind.Colon) {
				var start = tokens[code[step]].start;
				if (SyntaxAnnotator.endsCaseHeader(tokens, code, step))
					caseColons.set(start, true);
				if (pairsWithQuestion(step))
					ternaryColons.set(start, true);
			}
		for (step in 0...code.length)
			if (kind(step) == TokenKind.Colon) {
				var start = tokens[code[step]].start;
				if (caseColons.exists(start) || colonNeedsSpace(step))
					spacedColons.set(start, true);
			}
		for (step in 0...code.length)
			if (kind(step) == TokenKind.Arrow && step > 0 && kind(step - 1) != TokenKind.RightParen
				&& inTypePosition(step))
				tightArrows.set(tokens[code[step]].start, true);
	}

	inline function kind(step:Int):Null<TokenKind>
		return FormatTokenTools.syntaxKind(tokens[code[step]]);

	function opensTypeArguments(step:Int):Bool
		return syntax.typeArgumentOpens.exists(tokens[code[step]].start);

	function closesTypeArguments(step:Int):Bool
		return syntax.typeArgumentCloses.exists(tokens[code[step]].start);

	/** The code position of the bracket matching the one at `step`, or -1. */
	function matchOf(step:Int):Int {
		var other = syntax.matching.get(code[step]);
		return other == null || !position.exists(other) ? -1 : position.get(other);
	}

	/** Whether the bracket at `step` closes a group whose opener follows one of `keywords`. */
	function keywordBefore(step:Int, keywords:Array<TokenKind>):Bool {
		var open = matchOf(step);
		return open > 0 && keywords.indexOf(kind(open - 1)) >= 0;
	}

	function opensParameters(step:Int):Bool {
		var before = step - 1;
		if (before >= 0 && closesTypeArguments(before)) {
			// Skip the type parameters of `function name<T>(`.
			var open = matchOf(before);
			if (open < 0)
				return false;
			before = open - 1;
		}
		// The name: an identifier, or `new` for a constructor.
		if (before >= 0 && (kind(before) == TokenKind.Identifier || kind(before) == TokenKind.New))
			before--;
		return before >= 0 && kind(before) == TokenKind.Function;
	}

	/** `?` is the conditional operator only right after an operand; elsewhere it marks an optional parameter or field. */
	function isTernaryQuestion(index:Int):Bool {
		var previous = previousToken(index);
		if (previous < 0)
			return false;
		return switch FormatTokenTools.syntaxKind(tokens[previous]) {
			case TokenKind.Identifier, TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace,
				TokenKind.Integer, TokenKind.Float,
				TokenKind.StringLiteral, TokenKind.RegexLiteral, TokenKind.BoolTrue, TokenKind.BoolFalse,
				TokenKind.This, TokenKind.Increment,
				TokenKind.Decrement, TokenKind.TypeInt, TokenKind.TypeBool, TokenKind.TypeFloat, TokenKind.TypeString:
				true;
			default:
				false;
		};
	}

	/** A sign follows something that cannot end an operand: an opener, a separator, an operator, a keyword that starts an expression. */
	function isUnary(index:Int):Bool {
		var previous = previousToken(index);
		if (previous < 0)
			return true;
		var before = tokens[previous];
		if (!FormatTokenTools.isSyntax(before))
			return false;
		var kind = FormatTokenTools.syntaxKind(before);
		// After the `)` of a control header (`for (...) -1` in a comprehension) an expression begins.
		if (kind == TokenKind.RightParen)
			return position.exists(previous) && keywordBefore(position.get(previous), [
				TokenKind.If,
				TokenKind.For,
				TokenKind.While,
				TokenKind.Catch
			]);
		return switch kind {
			case TokenKind.LeftParen, TokenKind.LeftBracket, TokenKind.LeftBrace, TokenKind.RightBrace,
				TokenKind.Semicolon, TokenKind.Comma,
				TokenKind.Assign, TokenKind.Colon, TokenKind.Question, TokenKind.Return, TokenKind.Throw,
				TokenKind.Case, TokenKind.In,
				TokenKind.Arrow, TokenKind.Else, TokenKind.Do, TokenKind.PlusAssign, TokenKind.MinusAssign,
				TokenKind.StarAssign,
				TokenKind.SlashAssign, TokenKind.PercentAssign, TokenKind.AndAssign, TokenKind.OrAssign,
				TokenKind.XorAssign:
				true;
			default:
				TokenRoles.isBinaryOperator(kind);
		};
	}

	/** The nearest token before `index` that is not whitespace or a line break (a comment counts). */
	function previousToken(index:Int):Int {
		var previous = index - 1;
		while (previous >= 0 && (tokens[previous].kind == FormatTokenKind.Whitespace
			|| tokens[previous].kind == FormatTokenKind.Newline))
			previous--;
		return previous;
	}

	function endsMetadata(step:Int):Bool {
		var cursor = step;
		if (kind(cursor) == TokenKind.RightParen) {
			var open = matchOf(cursor);
			if (open < 0)
				return false;
			cursor = open - 1;
		}
		if (cursor < 0 || kind(cursor) != TokenKind.Identifier)
			return false;
		var before = cursor - 1;
		if (before >= 0 && kind(before) == TokenKind.Colon)
			before--;
		return before >= 0 && kind(before) == TokenKind.At;
	}


	/**
	 * A conditional's colon: an unmatched `?` of the same expression comes before it, at the same bracket depth, before a `,` or `;`
	 * ends the expression. Nested conditionals pair up (`a ? b : c ? d : e`).
	 */
	function pairsWithQuestion(colon:Int):Bool {
		var depth = 0, unmatchedColons = 0, step = colon - 1;
		while (step >= 0) {
			switch kind(step) {
				case TokenKind.RightParen | TokenKind.RightBracket | TokenKind.RightBrace:
					depth++;
				case TokenKind.LeftParen | TokenKind.LeftBracket | TokenKind.LeftBrace:
					if (depth == 0)
						return false;
					depth--;
				case TokenKind.Comma | TokenKind.Semicolon if (depth == 0):
					return false;
				case TokenKind.Colon if (depth == 0):
					unmatchedColons++;
				case TokenKind.Question if (depth == 0 && ternaryQuestions.exists(tokens[code[step]].start)):
					if (unmatchedColons == 0)
						return true;
					unmatchedColons--;
				default:
			}
			step--;
		}
		return false;
	}

	/**
	 * Whether a non-case colon is spaced: an object field's or a conditional's. Inside type arguments (`Array<{a:Int}>`) and in a
	 * typedef it annotates a type; inside an object literal (the nearest enclosing brace that is not a block) it names a field.
	 */
	function colonNeedsSpace(colon:Int):Bool {
		// The nearest enclosing brace that is not a block, if any; the walk goes on past it, since a structure type inside type
		// arguments (`Array<{a:Int}>`) is still a type.
		var depth = 0, step = colon - 1, typeDepth = 0, objectBrace = -1;
		while (step >= 0) {
			if (closesTypeArguments(step))
				typeDepth++;
			else if (opensTypeArguments(step)) {
				if (typeDepth == 0)
					return false;
				typeDepth--;
			} else
				switch kind(step) {
					case TokenKind.RightParen | TokenKind.RightBracket | TokenKind.RightBrace:
						depth++;
					case TokenKind.LeftParen | TokenKind.LeftBracket:
						if (depth > 0)
							depth--;
					case TokenKind.LeftBrace:
						if (depth > 0)
							depth--;
						else {
							var start = tokens[code[step]].start;
							if (!(syntax.blockOpens.exists(start) && !syntax.blockOpens.get(start)))
							// A block: the code inside it does not see the braces around it.
							break;
							if (objectBrace < 0)
								objectBrace = step;
						}
					case TokenKind.Typedef:
						return false;
					case TokenKind.Semicolon if (depth == 0):
						break;
					default:
				}
			step--;
		}
		if (objectBrace >= 0)
			return !insideTypedef(objectBrace) || ternaryColons.exists(tokens[code[colon]].start);
		return ternaryColons.exists(tokens[code[colon]].start);
	}

	/** Whether the brace at `step` is the body of a `typedef` (its fields are type annotations). */
	function insideTypedef(step:Int):Bool {
		var cursor = step - 1;
		while (cursor >= 0) {
			switch kind(cursor) {
				case TokenKind.Typedef:
					return true;
				case TokenKind.Semicolon | TokenKind.LeftBrace | TokenKind.RightBrace:
					return false;
				default:
			}
			cursor--;
		}
		return false;
	}

	/**
	 * Whether the token at `step` is part of a type: walking back at its bracket depth reaches a type annotation's `:`, an enclosing
	 * type argument list, or the `=` of a `typedef`, before anything that ends a type (`,`, `;`, `return`, an enclosing bracket).
	 */
	function inTypePosition(step:Int):Bool {
		var depth = 0, cursor = step - 1;
		while (cursor >= 0) {
			if (closesTypeArguments(cursor))
				depth++;
			else if (opensTypeArguments(cursor)) {
				if (depth == 0)
					return true;
				depth--;
			} else
				switch kind(cursor) {
					case TokenKind.RightParen | TokenKind.RightBracket | TokenKind.RightBrace:
						depth++;
					case TokenKind.LeftParen | TokenKind.LeftBracket | TokenKind.LeftBrace:
						if (depth == 0)
							return false;
						depth--;
					case TokenKind.Colon if (depth == 0):
						var start = tokens[code[cursor]].start;
						return !spacedColons.exists(start);
					case TokenKind.Assign if (depth == 0):
						return cursor >= 2 && kind(cursor - 2) == TokenKind.Typedef;
					case TokenKind.Comma | TokenKind.Semicolon | TokenKind.Return if (depth == 0):
						return false;
					default:
				}
			cursor--;
		}
		return false;
	}

	public static function isBinaryOperator(kind:Null<TokenKind>):Bool
		return kind != null
			&& (kind == TokenKind.AndAnd || kind == TokenKind.OrOr || kind == TokenKind.Plus || kind == TokenKind.Minus
			|| kind == TokenKind.Star || kind == TokenKind.Slash || kind == TokenKind.Percent
			|| kind == TokenKind.Ampersand
			|| kind == TokenKind.Pipe || kind == TokenKind.Caret || kind == TokenKind.NullCoalesce
			|| kind == TokenKind.Less
			|| kind == TokenKind.Greater || kind == TokenKind.LessEqual || kind == TokenKind.GreaterEqual
			|| kind == TokenKind.EqualEqual || kind == TokenKind.NotEqual || kind == TokenKind.Assign);
}
