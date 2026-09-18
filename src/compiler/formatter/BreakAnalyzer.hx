package compiler.formatter;

import compiler.syntax.Token.TokenKind;
import compiler.formatter.CstFormatterStructure.SyntaxInfo;
import compiler.formatter.CstFormatterStructure.FormatNodeKind;
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
				&& !(rightKind == TokenKind.Less && isGenericOpen(tokens, index + 1, syntax))) {
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
		var result:Array<DelimiterGroup> = [], indexByStart:Map<Int, Int> = [];
		for (index in 0...tokens.length)
			indexByStart.set(tokens[index].start, index);
		for (open in 0...tokens.length) {
			if (!isOpeningDelimiter(FormatTokenTools.syntaxKind(tokens[open])))
				continue;
			var closeStart = syntax.matchingByOffset.get(tokens[open].start);
			if (closeStart == null)
				continue;
			var close = indexByStart.get(closeStart);
			if (close == null || close <= open)
				continue;
			var commas:Array<Int> = [];
			for (index in open + 1...close)
				if (FormatTokenTools.syntaxKind(tokens[index]) == TokenKind.Comma)
					commas.push(index);
			result.push({
				open: open,
				close: close,
				commas: commas,
				kind: syntax.nodeKinds.get(tokens[open].start + ":" + tokens[close].start),
				expanded: false
			});
		}
		return result;
	}

	static function isOpeningDelimiter(kind:Null<TokenKind>):Bool
		return kind == TokenKind.LeftParen || kind == TokenKind.LeftBracket || kind == TokenKind.LeftBrace || kind == TokenKind.Less;

	static function spacing(tokens:Array<FormatToken>, index:Int, left:Null<TokenKind>, right:Null<TokenKind>, syntax:SyntaxInfo):Int {
		if (tokens[index + 1].kind == FormatTokenKind.LineComment
			|| tokens[index + 1].kind == FormatTokenKind.DocComment
			|| tokens[index + 1].kind == FormatTokenKind.BlockComment)
			return 1;
		if (left == null || right == null)
			return 0;
		if (right == TokenKind.Comma || right == TokenKind.Semicolon || right == TokenKind.Dot || right == TokenKind.RightParen
			|| right == TokenKind.RightBracket || right == TokenKind.RightBrace)
			return 0;
		if (left == TokenKind.LeftParen || left == TokenKind.LeftBracket || left == TokenKind.Dot)
			return 0;
		if (right == TokenKind.LeftParen)
			return left == TokenKind.If || left == TokenKind.While || left == TokenKind.For || left == TokenKind.Switch || left == TokenKind.Catch ? 1 : 0;
		if (right == TokenKind.Less && isGenericOpen(tokens, index + 1, syntax))
			return 0;
		if (left == TokenKind.Less && isGenericOpen(tokens, index, syntax))
			return 0;
		if (right == TokenKind.Greater && isGenericClose(tokens, index + 1, syntax))
			return 0;
		if (left == TokenKind.Greater
			&& isGenericClose(tokens, index, syntax)
			&& (right == TokenKind.LeftParen || right == TokenKind.LeftBracket || right == TokenKind.Dot || right == TokenKind.Comma
				|| right == TokenKind.Semicolon || right == TokenKind.RightParen || right == TokenKind.RightBracket || right == TokenKind.RightBrace
				|| right == TokenKind.Greater))
			return 0;
		if (left == TokenKind.LeftBrace)
			return 0;
		if (right == TokenKind.LeftBracket)
			return left == TokenKind.Assign || left == TokenKind.Return || left == TokenKind.Comma ? 1 : 0;
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
		var previous = FormatTokenTools.syntaxKind(tokens[index - 1]);
		return previous != TokenKind.LeftParen && previous != TokenKind.Comma && previous != TokenKind.Assign && previous != TokenKind.Colon;
	}

	static function isGenericOpen(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Bool
		return index >= 0 && index < tokens.length
			&& FormatTokenTools.syntaxKind(tokens[index]) == TokenKind.Less
			&& syntax.matchingByOffset.exists(tokens[index].start);

	static function isGenericClose(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Bool
		return index >= 0 && index < tokens.length
			&& FormatTokenTools.syntaxKind(tokens[index]) == TokenKind.Greater
			&& syntax.matchingByOffset.exists(tokens[index].start);

	static function colonNeedsSpace(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Bool {
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
			|| previous == TokenKind.Colon || previous == TokenKind.Question || isBinaryOperator(previous);
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
			|| kind == TokenKind.Ampersand || kind == TokenKind.Pipe || kind == TokenKind.Caret;

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
