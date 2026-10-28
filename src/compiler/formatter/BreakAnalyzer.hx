package compiler.formatter;

import compiler.syntax.Token.TokenKind;
import compiler.formatter.SyntaxAnnotator.SyntaxInfo;
import compiler.formatter.SyntaxAnnotator.FormatNodeKind;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;
import compiler.formatter.FormatConfig.FormatConfigTools;

private typedef DelimiterGroup = {
	final open:Int;
	final close:Int;
	final commas:Array<Int>;
	final kind:Null<FormatNodeKind>;
	final expanded:Bool;
}

/** Classifies token boundaries and turns overlong delimited groups into constraints. */
class BreakAnalyzer {
	public static function analyze(line:UnwrappedLine, syntax:SyntaxInfo, config:FormatConfig):Array<Boundary> {
		var tokens = line.tokens, groups = findGroups(tokens, syntax), expanded = [];
		for (group in groups)
			if (group.commas.length > 0
				&& groupPrefixWidth(tokens, group.open, line.indent, config, syntax) + rangeWidth(tokens, group.open, group.close, syntax) > config.lineWidth)
				expanded.push(group);

		var result:Array<Boundary> = [];
		var boundaryCount = tokens.length > 1 ? tokens.length - 1 : 0;
		for (index in 0...boundaryCount) {
			var left = tokens[index], right = tokens[index + 1], leftKind = FormatTokenTools.syntaxKind(left), rightKind = FormatTokenTools.syntaxKind(right),
				spaces = spacing(tokens, index, leftKind, rightKind, syntax), canBreak = false, mustBreak = false, penalty = 0,
				continuation = line.indent + FormatConfigTools.continuationLevels(config);
			if (left.kind == FormatTokenKind.LineComment || left.kind == FormatTokenKind.DocComment)
				mustBreak = true;
			else if (left.kind == FormatTokenKind.BlockComment && left.text.indexOf("\n") >= 0)
				mustBreak = true;
			else if (leftKind == TokenKind.Comma) {
				canBreak = true;
				penalty = 10;
			} else if (rightKind != null && isLogicalOperator(rightKind)) {
				canBreak = true;
				penalty = 20;
			} else if (rightKind != null
				&& isComparisonOperator(rightKind)
				&& !(rightKind == TokenKind.Less && opensTypeArguments(tokens, index + 1, syntax))) {
				canBreak = true;
				penalty = 25;
			} else if (rightKind == TokenKind.Question && isTernaryQuestion(tokens, index + 1)) {
				canBreak = true;
				penalty = 25;
			} else if (rightKind == TokenKind.Colon && ternaryColon(tokens, index)) {
				canBreak = true;
				penalty = 25;
			} else if (rightKind != null && isArithmeticOperator(rightKind)) {
				canBreak = true;
				penalty = 30;
			} else if (rightKind == TokenKind.Assign
				|| rightKind == TokenKind.PlusAssign
				|| rightKind == TokenKind.MinusAssign
				|| rightKind == TokenKind.StarAssign
				|| rightKind == TokenKind.SlashAssign
				|| rightKind == TokenKind.PercentAssign
				|| rightKind == TokenKind.AndAssign
				|| rightKind == TokenKind.OrAssign
				|| rightKind == TokenKind.XorAssign) {
				canBreak = true;
				penalty = 50;
			} else if (leftKind == TokenKind.Assign || leftKind == TokenKind.PlusAssign || leftKind == TokenKind.MinusAssign
				|| leftKind == TokenKind.StarAssign || leftKind == TokenKind.SlashAssign || leftKind == TokenKind.PercentAssign
				|| leftKind == TokenKind.AndAssign || leftKind == TokenKind.OrAssign || leftKind == TokenKind.XorAssign) {
				canBreak = true;
				penalty = 40;
			} else if (rightKind == TokenKind.Dot) {
				canBreak = true;
				penalty = 50;
			}
			if (rightKind == TokenKind.RightParen || rightKind == TokenKind.RightBracket || rightKind == TokenKind.RightBrace)
				continuation = line.indent;
			for (group in expanded)
				if (index == group.open || group.commas.indexOf(index) >= 0 || index + 1 == group.close) {
					mustBreak = true;
					canBreak = true;
					if (index == group.open || index + 1 == group.close)
						continuation = index + 1 == group.close ? line.indent : line.indent + FormatConfigTools.continuationLevels(config);
					if (penalty == 0)
						penalty = 10;
				}
			// The parser recognizes shifts and their assignments by source adjacency.
			// Never put whitespace or a wrapping boundary inside these operators.
			if (adjacentShiftParts(left, right)) {
				spaces = 0;
				canBreak = false;
				mustBreak = false;
			}
			result.push({
				spaces: spaces,
				canBreak: canBreak,
				mustBreak: mustBreak,
				penalty: penalty,
				continuationIndent: continuation
			});
		}
		return result;
	}

	public static function flatText(line:UnwrappedLine, boundaries:Array<Boundary>):String {
		var output = new StringBuf();
		for (index in 0...line.tokens.length) {
			if (index > 0)
				addSpaces(output, boundaries[index - 1].spaces);
			output.add(line.tokens[index].text);
		}
		return output.toString();
	}

	static function findGroups(tokens:Array<FormatToken>, syntax:SyntaxInfo):Array<DelimiterGroup> {
		var result:Array<DelimiterGroup> = [],
			stack:Array<{open:Int, closeKind:TokenKind, commas:Array<Int>}> = [];
		for (index in 0...tokens.length) {
			var kind = FormatTokenTools.syntaxKind(tokens[index]);
			if (kind == null)
				continue;
			switch kind {
				case TokenKind.LeftParen:
					stack.push({open: index, closeKind: TokenKind.RightParen, commas: []});
				case TokenKind.LeftBracket:
					stack.push({open: index, closeKind: TokenKind.RightBracket, commas: []});
				case TokenKind.LeftBrace:
					stack.push({open: index, closeKind: TokenKind.RightBrace, commas: []});
				case TokenKind.Less:
					if (opensTypeArguments(tokens, index, syntax))
						stack.push({open: index, closeKind: TokenKind.Greater, commas: []});
				case TokenKind.Comma:
					if (stack.length > 0)
						stack[stack.length - 1].commas.push(index);
				case TokenKind.Greater, TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace:
					if (stack.length > 0 && stack[stack.length - 1].closeKind == kind) {
						var group = stack.pop();
						result.push({
							open: group.open,
							close: index,
							commas: group.commas,
							kind: syntax.nodeKinds.get(tokens[group.open].start + ":" + tokens[index].start),
							expanded: false
						});
					}
				default:
			}
		}
		return result;
	}

	/** Adjacent token pieces that are one operator in source: `<<`, `>>=`, and the map arrow `=>`. */
	static function adjacentShiftParts(left:FormatToken, right:FormatToken):Bool {
		if (left.end != right.start)
			return false;
		var leftKind = FormatTokenTools.syntaxKind(left),
			rightKind = FormatTokenTools.syntaxKind(right);
		return (leftKind == TokenKind.Assign && rightKind == TokenKind.Greater)
			|| (leftKind == TokenKind.Less && (rightKind == TokenKind.Less || rightKind == TokenKind.LessEqual))
			|| (leftKind == TokenKind.Greater && (rightKind == TokenKind.Greater || rightKind == TokenKind.GreaterEqual));
	}

	static function spacing(tokens:Array<FormatToken>, index:Int, left:Null<TokenKind>, right:Null<TokenKind>, syntax:SyntaxInfo):Int {
		if (tokens[index + 1].kind == FormatTokenKind.LineComment
			|| tokens[index + 1].kind == FormatTokenKind.DocComment
			|| tokens[index + 1].kind == FormatTokenKind.BlockComment)
			return 1;
		if (adjacentShiftParts(tokens[index], tokens[index + 1]))
			return 0;
		if (left == null || right == null)
			return 0;
		if (right == TokenKind.Comma || right == TokenKind.Semicolon || right == TokenKind.Dot || right == TokenKind.RightParen
			|| right == TokenKind.RightBracket || right == TokenKind.RightBrace)
			return 0;
		if (left == TokenKind.LeftParen || left == TokenKind.LeftBracket || left == TokenKind.Dot)
			return 0;
		if (right == TokenKind.Less && opensTypeArguments(tokens, index + 1, syntax))
			return 0;
		if (left == TokenKind.Less && opensTypeArguments(tokens, index, syntax))
			return 0;
		if (right == TokenKind.Greater && closesTypeArguments(tokens, index + 1, syntax))
			return 0;
		if (right == TokenKind.LeftParen && left != TokenKind.Colon && left != TokenKind.Comma && left != TokenKind.LeftBrace)
			return endsOperand(tokens, index, left, syntax) || isPrefixOperator(tokens, index, left) ? 0 : 1;
		if (right == TokenKind.LeftBracket && left != TokenKind.Colon && left != TokenKind.Comma && left != TokenKind.LeftBrace)
			return endsOperand(tokens, index, left, syntax) || isPrefixOperator(tokens, index, left) ? 0 : 1;
		if (left == TokenKind.Greater
			&& closesTypeArguments(tokens, index, syntax)
			&& (right == TokenKind.LeftParen || right == TokenKind.LeftBracket || right == TokenKind.Dot || right == TokenKind.Comma
				|| right == TokenKind.Semicolon || right == TokenKind.RightParen || right == TokenKind.RightBracket || right == TokenKind.RightBrace
				|| right == TokenKind.Greater))
			return 0;
		if (left == TokenKind.LeftBrace)
			return 0;
		if (right == TokenKind.LeftBrace)
			return 1;
		if (left == TokenKind.Comma)
			return 1;
		if (left == TokenKind.Colon)
			return colonNeedsSpace(tokens, index, syntax) ? 1 : 0;
		if (right == TokenKind.Colon)
			return ternaryColon(tokens, index) ? 1 : 0;
		if (left == TokenKind.At)
			return 0;
		if (left == TokenKind.Question && !isTernaryQuestion(tokens, index))
			return 0;
		if (right == TokenKind.Increment || right == TokenKind.Decrement || left == TokenKind.Not || left == TokenKind.BitNot)
			return 0;
		if (isUnary(tokens, index, left))
			return 0;
		return 1;
	}

	static function ternaryColon(tokens:Array<FormatToken>, index:Int):Bool {
		for (cursor in 0...index)
			if (isTernaryQuestion(tokens, cursor))
				return true;
		return false;
	}

	static function isTernaryQuestion(tokens:Array<FormatToken>, index:Int):Bool {
		if (index < 0 || index >= tokens.length || FormatTokenTools.syntaxKind(tokens[index]) != TokenKind.Question)
			return false;
		if (index == 0)
			return false;
		// `?` is the conditional operator only after an operand; elsewhere it marks an optional parameter or field.
		return switch FormatTokenTools.syntaxKind(tokens[index - 1]) {
			case TokenKind.Identifier, TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace, TokenKind.Integer, TokenKind.Float,
				TokenKind.StringLiteral, TokenKind.RegexLiteral, TokenKind.BoolTrue, TokenKind.BoolFalse, TokenKind.This, TokenKind.Increment,
				TokenKind.Decrement, TokenKind.TypeInt, TokenKind.TypeBool, TokenKind.TypeFloat, TokenKind.TypeString:
				true;
			default: false;
		};
	}

	static function opensTypeArguments(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Bool
		return index >= 0 && index < tokens.length && syntax.typeArgumentOpens.exists(tokens[index].start);

	static function closesTypeArguments(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Bool
		return index >= 0 && index < tokens.length && syntax.typeArgumentCloses.exists(tokens[index].start);

	/** Can this token end an operand, so that a following `(` or `[` is a call or an index rather than a new expression? */
	static function endsOperand(tokens:Array<FormatToken>, index:Int, kind:Null<TokenKind>, syntax:SyntaxInfo):Bool
		return switch kind {
			case TokenKind.Identifier, TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace, TokenKind.This, TokenKind.New,
				TokenKind.Function, TokenKind.StringLiteral, TokenKind.Integer, TokenKind.Float, TokenKind.BoolTrue, TokenKind.BoolFalse,
				TokenKind.TypeInt, TokenKind.TypeBool, TokenKind.TypeFloat, TokenKind.TypeString, TokenKind.Dollar:
				true;
			case TokenKind.Greater: closesTypeArguments(tokens, index, syntax);
			default: false;
		};

	/** A prefix operator binds to what follows it without a space: `!(a)`, `-(a)`, `@:meta`. */
	static function isPrefixOperator(tokens:Array<FormatToken>, index:Int, kind:Null<TokenKind>):Bool
		return kind == TokenKind.Not || kind == TokenKind.BitNot || kind == TokenKind.Increment || kind == TokenKind.Decrement || kind == TokenKind.At
			|| isUnary(tokens, index, kind);

	static function colonNeedsSpace(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Bool {
		// A structure type inside type arguments, `Array<{a:Int}>`, is annotated like any other type.
		var typeDepth = 0;
		for (cursor in 0...index) {
			if (syntax.typeArgumentOpens.exists(tokens[cursor].start))
				typeDepth++;
			else if (syntax.typeArgumentCloses.exists(tokens[cursor].start))
				typeDepth--;
		}
		if (typeDepth > 0)
			return false;
		// The body of a typedef declares field types, like `{a:Int}` above.
		for (cursor in 0...index)
			if (FormatTokenTools.syntaxKind(tokens[cursor]) == TokenKind.Typedef)
				return false;
		var objectDepth = 0;
		for (cursor in 0...index + 1) {
			var token = tokens[cursor],
				kind = FormatTokenTools.syntaxKind(token);
			if (kind == TokenKind.LeftBrace && syntax.blockOpens.exists(token.start) && !syntax.blockOpens.get(token.start))
				objectDepth++;
			else if (kind == TokenKind.RightBrace && objectDepth > 0)
				objectDepth--;
		}
		if (objectDepth > 0)
			return true;
		for (cursor in 0...index)
			if (isTernaryQuestion(tokens, cursor))
				return true;
		return false;
	}

	static function isUnary(tokens:Array<FormatToken>, index:Int, kind:Null<TokenKind>):Bool {
		if (kind != TokenKind.Plus && kind != TokenKind.Minus)
			return false;
		if (index == 0)
			return true;
		var previous = FormatTokenTools.syntaxKind(tokens[index - 1]);
		return previous == TokenKind.LeftParen || previous == TokenKind.LeftBracket || previous == TokenKind.Comma || previous == TokenKind.Assign
			|| previous == TokenKind.Colon || previous == TokenKind.Question || previous == TokenKind.Return || previous == TokenKind.Throw
			|| previous == TokenKind.Case || previous == TokenKind.In || previous == TokenKind.Arrow || previous == TokenKind.Else
			|| previous == TokenKind.Do || previous == TokenKind.PlusAssign || previous == TokenKind.MinusAssign || previous == TokenKind.StarAssign
			|| previous == TokenKind.SlashAssign || previous == TokenKind.PercentAssign || previous == TokenKind.AndAssign
			|| previous == TokenKind.OrAssign || previous == TokenKind.XorAssign || isBinaryOperator(previous);
	}

	static function isBinaryOperator(kind:Null<TokenKind>):Bool
		return kind != null
			&& (isLogicalOperator(kind) || isArithmeticOperator(kind) || kind == TokenKind.Less || kind == TokenKind.Greater || kind == TokenKind.LessEqual
				|| kind == TokenKind.GreaterEqual || kind == TokenKind.EqualEqual || kind == TokenKind.NotEqual || kind == TokenKind.Assign);

	static function isComparisonOperator(kind:TokenKind):Bool
		return kind == TokenKind.LessEqual || kind == TokenKind.GreaterEqual || kind == TokenKind.EqualEqual || kind == TokenKind.NotEqual
			|| kind == TokenKind.Less || kind == TokenKind.Greater;

	static function isLogicalOperator(kind:TokenKind):Bool
		return kind == TokenKind.AndAnd || kind == TokenKind.OrOr;

	static function isArithmeticOperator(kind:TokenKind):Bool
		return kind == TokenKind.Plus || kind == TokenKind.Minus || kind == TokenKind.Star || kind == TokenKind.Slash || kind == TokenKind.Percent
			|| kind == TokenKind.Ampersand || kind == TokenKind.Pipe || kind == TokenKind.Caret || kind == TokenKind.NullCoalesce;

	static function flatWidth(tokens:Array<FormatToken>, indent:Int, config:FormatConfig, syntax:SyntaxInfo):Int {
		var width = indent * config.indentWidth;
		for (index in 0...tokens.length) {
			if (index > 0)
				width += spacing(tokens, index - 1, FormatTokenTools.syntaxKind(tokens[index - 1]), FormatTokenTools.syntaxKind(tokens[index]), syntax);
			width += tokens[index].text.length;
		}
		return width;
	}

	static function groupPrefixWidth(tokens:Array<FormatToken>, open:Int, indent:Int, config:FormatConfig, syntax:SyntaxInfo):Int
		return indent * config.indentWidth
			+ (open == 0 ? 0 : rangeWidth(tokens, 0, open - 1, syntax))
			+ (open == 0 ? 0 : spacing(tokens, open - 1, FormatTokenTools.syntaxKind(tokens[open - 1]), FormatTokenTools.syntaxKind(tokens[open]), syntax));

	static function rangeWidth(tokens:Array<FormatToken>, start:Int, end:Int, syntax:SyntaxInfo):Int {
		if (start > end)
			return 0;
		var width = 0;
		for (index in start...end + 1) {
			if (index > start)
				width += spacing(tokens, index - 1, FormatTokenTools.syntaxKind(tokens[index - 1]), FormatTokenTools.syntaxKind(tokens[index]), syntax);
			width += tokens[index].text.length;
		}
		return width;
	}

	static function addSpaces(output:StringBuf, count:Int):Void
		for (_ in 0...count)
			output.add(" ");
}
