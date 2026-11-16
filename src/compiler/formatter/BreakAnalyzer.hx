package compiler.formatter;

import compiler.formatter.Boundary.BreakLayout;
import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;
import compiler.formatter.SyntaxAnnotator.FormatNodeKind;
import compiler.formatter.SyntaxAnnotator.SyntaxInfo;
import compiler.formatter.UnwrappedLine.UnwrappedLineTools;
import compiler.syntax.Token.TokenKind;

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
		var tokens = line.tokens,
			groups = findGroups(tokens, syntax),
			expanded:Array<DelimiterGroup> = [];
		// Outermost first: a group inside an expanded one starts its own line, so only the part of the line before it counts.
		groups.sort((left, right) -> left.open - right.open);
		// A type is read whole: no break directly inside a type argument list (`Map<String, Int>`), though a structure type nested
		// in one (`Array<{...}>`) still lays out its fields. insideTypeArguments[i] covers the boundary after token i.
		var insideTypeArguments:Array<Bool> = [], brackets:Array<Bool> = [];
		for (index in 0...tokens.length) {
			if (opensTypeArguments(tokens, index, syntax))
				brackets.push(true);
			else if (closesTypeArguments(tokens, index, syntax))
				brackets.pop();
			else
				switch FormatTokenTools.syntaxKind(tokens[index]) {
					case TokenKind.LeftParen | TokenKind.LeftBracket | TokenKind.LeftBrace:
						brackets.push(false);
					case TokenKind.RightParen | TokenKind.RightBracket | TokenKind.RightBrace:
						brackets.pop();
					default:
				}
			var next = index + 1 < tokens.length && closesTypeArguments(tokens, index + 1, syntax);
			insideTypeArguments.push(next || brackets.length > 0 && brackets[brackets.length - 1]);
		}
		// Where a break may go at all, before any group is laid out (see opportunity).
		var breakable = [
			for (index in 0...tokens.length - 1)
				!insideTypeArguments[index]
				&& opportunity(tokens, index, FormatTokenTools.syntaxKind(tokens[index]),
				FormatTokenTools.syntaxKind(tokens[index + 1]), syntax) >= 0
		];
		// An over-long array or object literal goes one element per line. An over-long argument or parameter list is filled instead:
		// its commas stay break opportunities and the line breaker wraps as late as it can, onto a continuation line, as this code
		// has always been written. A group holding a line comment is always laid out one element per line.
		// A literal its author wrote expanded with several elements on a line (instruction lists, tables) stays expanded and filled:
		// its brackets on their own lines, its elements packed between them. filledBreaks are its commas and its comments' line ends.
		var filled:Array<DelimiterGroup> = [], filledBreaks = new Map<Int, Bool>();
		for (group in groups)
			if (writtenExpanded(line, group, syntax) && writtenFilled(line, group)) {
				filled.push(group);
				for (index in directMembers(tokens, group))
					switch tokens[index].kind {
						case FormatTokenKind.LineComment | FormatTokenKind.DocComment:
							filledBreaks.set(index, true);
						default:
							if (FormatTokenTools.syntaxKind(tokens[index]) == TokenKind.Comma)
								filledBreaks.set(index, true);
					}
			}
		for (group in groups)
			if (filled.indexOf(group) >= 0)
				continue;
			else if (holdsLineComment(tokens, group)
				|| writtenExpanded(line, group, syntax)
				|| group.commas.length > 0
				&& FormatTokenTools.syntaxKind(tokens[group.open]) != TokenKind.LeftParen
				&& !opensTypeArguments(tokens, group.open, syntax)
				&& groupPrefixWidth(line, breakable, group.open, expanded, line.indent, config,
				syntax) + rangeWidth(line, group.open, group.close, syntax) > config.lineWidth)
				expanded.push(group);

		// A function's parameter list wraps two continuation levels deep, so its parameters never line up with the body.
		var parameterCommas = new Map<Int, Bool>();
		for (group in groups)
			if (syntax.roles.parameterOpens.exists(tokens[group.open].start))
				for (comma in group.commas)
					parameterCommas.set(comma, true);


		// A `var` or `final` declaring several names that does not fit on one line puts one declarator per line.
		// So does one its author wrote one declarator per line (a line break after any of its declarator commas).
		var declaratorCommas = declarators(tokens, syntax);
		if (flatWidth(line, config, syntax) <= config.lineWidth && !writtenOnePerLine(line, declaratorCommas))
			declaratorCommas = new Map<Int, Bool>();

		var result:Array<Boundary> = [], levels = FormatConfigTools.continuationLevels(config), depth = 0,
		// A structural break a trailing comment displaced (it stays after the comment instead of before it).
		carried:Null<BreakLayout> = null;
		var boundaryCount = tokens.length > 1 ? tokens.length - 1 : 0;
		for (index in 0...boundaryCount) {
			var left = tokens[index],
				right = tokens[index + 1],
				leftKind = FormatTokenTools.syntaxKind(left),
				rightKind = FormatTokenTools.syntaxKind(right),
				spaces = spacing(tokens, index, leftKind, rightKind, syntax),
				canBreak = false,
				mustBreak = false,
				penalty = 0,
				layout:BreakLayout = Wrap(1);
			switch leftKind {
				case TokenKind.LeftParen | TokenKind.LeftBracket | TokenKind.LeftBrace:
					depth++;
				case TokenKind.RightParen | TokenKind.RightBracket | TokenKind.RightBrace:
					depth = depth > 0 ? depth - 1 : 0;
				default:
			}
			if (carried != null) {
				// The break before a trailing comment moved here, after it.
				mustBreak = true;
				canBreak = true;
				layout = carried;
				carried = null;
			} else if (left.kind.match(FormatTokenKind.LineComment) || left.kind.match(FormatTokenKind.DocComment))
				mustBreak = true;
			else if (left.kind.match(FormatTokenKind.BlockComment) && left.text.indexOf("\n") >= 0)
				mustBreak = true;
			else {
				var opportunityPenalty = opportunity(tokens, index, leftKind, rightKind, syntax);
				if (opportunityPenalty >= 0 && (rightKind == TokenKind.Catch || rightKind == TokenKind.Else)
					&& startsWithTryOrIf(tokens)) {
					// The `catch` of a `try` statement, or the `else` of an `if`, lines up with it.
					canBreak = true;
					penalty = opportunityPenalty;
					layout = At(line.indent);
				} else if (opportunityPenalty >= 0
					&& (leftKind == TokenKind.Try || leftKind == TokenKind.RightParen
					&& syntax.roles.controlHeaderCloses.exists(tokens[index].start))) {
					// A body moved below its header (`if (c)`, `for (...)`, `try`) is an element of its own, one level in: its own wraps
					// are relative to it, exactly as when the body was written on its own line.
					canBreak = true;
					penalty = opportunityPenalty;
					// A statement's body sits one level past the statement however its header wrapped, as the line builder places a
					// body written on its own line; a nested one (a comprehension's) wraps one level past its element.
					layout = headerBeginsLine(tokens, index, leftKind) ? At(line.indent + levels) : Wrap(1);
				} else if (opportunityPenalty >= 0) {
					canBreak = true;
					penalty = opportunityPenalty;
					if (leftKind == TokenKind.Comma && parameterCommas.exists(index))
						layout = Wrap(2);
				}
			}
			// A type is read whole, even where its author split it.
			if (insideTypeArguments[index])
				canBreak = false;
			// A line break its author put at a break opportunity is kept: the formatter adds breaks to lines that are too long and
			// normalizes spacing and indentation, but does not join what was split on purpose.
			if (canBreak && UnwrappedLineTools.beganSourceLine(line, right))
				mustBreak = true;
			// Metadata written on its own line stays there, above its declaration at the same indent.
			if (syntax.roles.metadataEnds.exists(tokens[index].start) && UnwrappedLineTools.beganSourceLine(line, right)) {
				canBreak = true;
				mustBreak = true;
				layout = At(line.indent);
			}
			// The deeper inside brackets a wrap would fall, the dearer it is, so a line breaks at its outermost level first.
			if (canBreak && !mustBreak)
				penalty += 15 * depth;
			for (group in filled)
				if (index == group.open || index + 1 == group.close) {
					mustBreak = true;
					canBreak = true;
					layout = index == group.open ? Open : Close;
				}
			if (filledBreaks.exists(index)) {
				// The author's rows are kept (a table stays a table); a row wider than the line wraps at its commas.
				canBreak = true;
				mustBreak = mustBreak || UnwrappedLineTools.beganSourceLine(line, right);
				layout = Separator;
				if (penalty == 0)
					penalty = 10;
			}
			for (group in expanded)
				if (index == group.open || group.commas.indexOf(index) >= 0 || index + 1 == group.close) {
					mustBreak = true;
					canBreak = true;
					layout = index == group.open ? Open : index + 1 == group.close ? Close : Separator;
					if (penalty == 0)
						penalty = 10;
				}
			if (insideTypeArguments[index] && !mustBreak)
				canBreak = false;
			if (declaratorCommas.exists(index)) {
				mustBreak = true;
				canBreak = true;
				layout = At(line.indent + levels);
			}
			// Whatever the rules above decided, a comment trailing code stays on its line: moving it would change what it describes, and
			// the next pass would see a leading comment and move it again. The break any rule wanted here happens after the comment,
			// which always ends its line.
			if (UnwrappedLineTools.isTrailingComment(line, right)) {
				if (mustBreak && !layout.match(Wrap(_)))
					carried = layout;
				canBreak = false;
				mustBreak = false;
			}
			// Preserve shifts and compound lexer tokens split only for type annotation.
			// Neither spaces nor wrapping may change their original token boundaries.
			if (adjacentOperatorParts(left, right)) {
				spaces = 0;
				canBreak = false;
				mustBreak = false;
			}
			result.push({
				spaces: spaces,
				canBreak: canBreak,
				mustBreak: mustBreak,
				penalty: penalty,
				layout: layout
			});
		}
		return result;
	}

	/**
	 * An array or object literal whose first element begins its own source line was written one element per line, and stays so. Only
	 * literals: an argument or parameter list is filled, a type is read whole, and a block is laid out by statements anyway.
	 */
	static function writtenExpanded(line:UnwrappedLine, group:DelimiterGroup, syntax:SyntaxInfo):Bool {
		var tokens = line.tokens, open = tokens[group.open];
		switch FormatTokenTools.syntaxKind(open) {
			case TokenKind.LeftBracket:
			case TokenKind.LeftBrace if (syntax.blockOpens.exists(open.start) && !syntax.blockOpens.get(open.start)):
			default:
				return false;
		}
		if (opensTypeArguments(tokens, group.open, syntax) || group.open + 1 >= group.close)
			return false;
		return UnwrappedLineTools.beganSourceLine(line, tokens[group.open + 1]);
	}

	/** Whether some element of a group shares its source line with the one before it: the author packed elements per line. */
	static function writtenFilled(line:UnwrappedLine, group:DelimiterGroup):Bool {
		for (comma in group.commas)
			if (comma + 1 < group.close && !UnwrappedLineTools.beganSourceLine(line, line.tokens[comma + 1])
				&& !UnwrappedLineTools.isTrailingComment(line, line.tokens[comma + 1]))
				return true;
		return false;
	}

	/** The token indices directly inside a group: not inside a bracket nested in it. */
	static function directMembers(tokens:Array<FormatToken>, group:DelimiterGroup):Array<Int> {
		var result = [], depth = 0;
		for (index in group.open + 1...group.close) {
			switch FormatTokenTools.syntaxKind(tokens[index]) {
				case TokenKind.LeftParen | TokenKind.LeftBracket | TokenKind.LeftBrace:
					depth++;
				case TokenKind.RightParen | TokenKind.RightBracket | TokenKind.RightBrace:
					depth--;
				default:
					if (depth == 0)
						result.push(index);
			}
		}
		return result;
	}

	static function writtenOnePerLine(line:UnwrappedLine, commas:Map<Int, Bool>):Bool {
		for (comma in commas.keys())
			if (comma + 1 < line.tokens.length && UnwrappedLineTools.beganSourceLine(line, line.tokens[comma + 1]))
				return true;
		return false;
	}

	/** The top-level commas of a statement that begins `var` or `final` (after modifiers): the ones between its declarators. */
	static function declarators(tokens:Array<FormatToken>, syntax:SyntaxInfo):Map<Int, Bool> {
		var result = new Map<Int, Bool>(), index = 0;
		while (index < tokens.length && !FormatTokenTools.isSyntax(tokens[index]))
			index++;
		var declaration = false;
		while (index < tokens.length) {
			switch FormatTokenTools.syntaxKind(tokens[index]) {
				case TokenKind.Public | TokenKind.Private | TokenKind.Static | TokenKind.Inline:
					index++;
					continue;
				case TokenKind.Var | TokenKind.Final:
					declaration = true;
				default:
			}
			break;
		}
		if (!declaration)
			return result;
		// Only real brackets nest: a type argument `<` / `>` does, a comparison or the `>` of a map's `=>` does not.
		var depth = 0;
		for (position in index...tokens.length) {
			var start = tokens[position].start;
			if (syntax.typeArgumentOpens.exists(start))
				depth++;
			else if (syntax.typeArgumentCloses.exists(start))
				depth--;
			else
				switch FormatTokenTools.syntaxKind(tokens[position]) {
					case TokenKind.LeftParen | TokenKind.LeftBracket | TokenKind.LeftBrace:
						depth++;
					case TokenKind.RightParen | TokenKind.RightBracket | TokenKind.RightBrace:
						depth--;
					case TokenKind.Comma if (depth == 0):
						result.set(position, true);
					default:
				}
		}
		return result;
	}




	/**
	 * The penalty of breaking between tokens `index` and `index + 1`, or -1 where no break may go. Both the group decisions (whether
	 * a line its author began there stays) and the boundaries themselves read it, so they cannot disagree.
	 */
	static function opportunity(tokens:Array<FormatToken>, index:Int, leftKind:Null<TokenKind>,
			rightKind:Null<TokenKind>, syntax:SyntaxInfo):Int {
		if (leftKind == TokenKind.Comma) {
			return 10;
		} else if (rightKind != null && isLogicalOperator(rightKind)) {
			return 20;
		} else if (rightKind != null
			&& isComparisonOperator(rightKind)
			&& !(rightKind == TokenKind.Less && opensTypeArguments(tokens, index + 1, syntax))) {
			return 25;
		} else if (rightKind == TokenKind.Question && syntax.roles.ternaryQuestions.exists(tokens[index + 1].start)) {
			return 25;
		} else if (rightKind == TokenKind.Colon && syntax.roles.ternaryColons.exists(tokens[index + 1].start)) {
			// Dearer than the break before `?`, so a wrapped ternary keeps `? a : b` together.
			return 30;
		} else if (rightKind != null && isArithmeticOperator(rightKind)) {
			return 30;
		} else if (rightKind == TokenKind.Assign
			|| rightKind == TokenKind.PlusAssign
			|| rightKind == TokenKind.MinusAssign
			|| rightKind == TokenKind.StarAssign
			|| rightKind == TokenKind.SlashAssign
			|| rightKind == TokenKind.PercentAssign
			|| rightKind == TokenKind.AndAssign
			|| rightKind == TokenKind.OrAssign
			|| rightKind == TokenKind.XorAssign) {
			return 50;
		} else if (leftKind == TokenKind.Assign || leftKind == TokenKind.PlusAssign || leftKind == TokenKind.MinusAssign
			|| leftKind == TokenKind.StarAssign || leftKind == TokenKind.SlashAssign
			|| leftKind == TokenKind.PercentAssign
			|| leftKind == TokenKind.AndAssign || leftKind == TokenKind.OrAssign || leftKind == TokenKind.XorAssign) {
			return 40;
		} else if (rightKind == TokenKind.Dot && !loneReceiver(tokens, index)) {
			return 50;
		}
		// `try x catch (e) y` and `if (c) x else y` may break before `catch` and `else`, after `try`, after a `catch (...)`,
		// `if (...)` or `for (...)` header that a body follows on the same logical line (a comprehension, a try written out), and
		// before a case guard (`case A if (...)`).
		if (rightKind == TokenKind.Catch || rightKind == TokenKind.Else || leftKind == TokenKind.Try)
			return 40;
		if (leftKind == TokenKind.RightParen && syntax.roles.controlHeaderCloses.exists(tokens[index].start))
			return 40;
		if (rightKind == TokenKind.If && leftKind != TokenKind.Else)
			return 40;
		return -1;
	}

	/** Whether the header ending at `index` (`try`, or the `)` of `if`/`for`/`while`/`catch`) belongs to the statement that begins the line. */
	static function headerBeginsLine(tokens:Array<FormatToken>, index:Int, leftKind:Null<TokenKind>):Bool {
		var keyword = index;
		if (leftKind == TokenKind.RightParen) {
			var depth = 0;
			while (keyword >= 0) {
				switch FormatTokenTools.syntaxKind(tokens[keyword]) {
					case TokenKind.RightParen: depth++;
					case TokenKind.LeftParen:
						depth--;
						if (depth == 0)
							break;
					default:
				}
				keyword--;
			}
			keyword = FormatTokenTools.previousSyntax(tokens, keyword);
		}
		if (keyword < 0)
			return false;
		// Only `}` and `else` may come before it on the line: `} else if (...)`, `} catch (...)`.
		var cursor = FormatTokenTools.previousSyntax(tokens, keyword);
		while (cursor >= 0) {
			switch FormatTokenTools.syntaxKind(tokens[cursor]) {
				case TokenKind.RightBrace | TokenKind.Else:
				default:
					return false;
			}
			cursor = FormatTokenTools.previousSyntax(tokens, cursor);
		}
		return true;
	}

	static function startsWithTryOrIf(tokens:Array<FormatToken>):Bool {
		for (token in tokens)
			if (FormatTokenTools.isSyntax(token))
				return switch FormatTokenTools.syntaxKind(token) {
					case TokenKind.Try | TokenKind.If: true;
					default: false;
				};
		return false;
	}


	/** Whether the token at `index` is a name standing alone before a `.` (`explorer.caption`): splitting there gains nothing. */
	static function loneReceiver(tokens:Array<FormatToken>, index:Int):Bool {
		switch FormatTokenTools.syntaxKind(tokens[index]) {
			case TokenKind.Identifier | TokenKind.This:
			default:
				return false;
		}
		var previous = FormatTokenTools.previousSyntax(tokens, index);
		return previous < 0 || FormatTokenTools.syntaxKind(tokens[previous]) != TokenKind.Dot;
	}



	/**
	 * A line comment directly inside a group (not inside a group nested in it) needs a line break there, so the group is laid out one
	 * element per line rather than half-flat.
	 */
	static function holdsLineComment(tokens:Array<FormatToken>, group:DelimiterGroup):Bool {
		var depth = 0;
		for (index in group.open + 1...group.close)
			switch tokens[index].kind {
				case FormatTokenKind.LineComment | FormatTokenKind.DocComment if (depth == 0):
					return true;
				case FormatTokenKind.Syntax(TokenKind.LeftParen | TokenKind.LeftBrace | TokenKind.LeftBracket):
					depth++;
				case FormatTokenKind.Syntax(TokenKind.RightParen | TokenKind.RightBrace | TokenKind.RightBracket):
					depth--;
				default:
			}
		return false;
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
						stack.push({
							open: index,
							closeKind: TokenKind.Greater,
							commas: []
						});
				case TokenKind.Comma:
					if (stack.length > 0)
						stack[stack.length - 1].commas.push(index);
				case TokenKind.Greater, TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace:
					if (stack.length > 0 && stack[stack.length - 1].closeKind == kind) {
						var group = stack[stack.length - 1];
						stack.pop();
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
	static function adjacentOperatorParts(left:FormatToken, right:FormatToken):Bool {
		if (left.end != right.start)
			return false;
		var leftKind = FormatTokenTools.syntaxKind(left),
			rightKind = FormatTokenTools.syntaxKind(right);
		return (leftKind == TokenKind.Assign && rightKind == TokenKind.Greater)
			|| (leftKind == TokenKind.Greater && rightKind == TokenKind.Assign)
			|| (leftKind == TokenKind.Less && (rightKind == TokenKind.Less || rightKind == TokenKind.LessEqual))
			|| (leftKind == TokenKind.Greater
			&& (rightKind == TokenKind.Greater || rightKind == TokenKind.GreaterEqual));
	}

	static function spacing(tokens:Array<FormatToken>, index:Int, left:Null<TokenKind>, right:Null<TokenKind>, syntax:SyntaxInfo):Int {
		if (tokens[index + 1].kind.match(FormatTokenKind.LineComment)
			|| tokens[index + 1].kind.match(FormatTokenKind.DocComment)
			|| tokens[index + 1].kind.match(FormatTokenKind.BlockComment))
			return 1;
		if (adjacentOperatorParts(tokens[index], tokens[index + 1]))
			return 0;
		// Next to a directive inside a line, the source's spacing stands: a directive's condition runs to where its text ends
		// (`#if eval || Sys.systemName`), so adding or removing a space could change what it reads.
		if (tokens[index].kind == FormatTokenKind.Directive || tokens[index + 1].kind == FormatTokenKind.Directive)
			return tokens[index].end == tokens[index + 1].start ? 0 : 1;
		if (left == null || right == null)
			return 0;
		if (right == TokenKind.Comma || right == TokenKind.Semicolon || right == TokenKind.Dot
			|| right == TokenKind.RightParen
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
		if (right == TokenKind.LeftParen && left != TokenKind.Colon && left != TokenKind.Comma
			&& left != TokenKind.LeftBrace)
			return endsOperand(tokens, index, left, syntax) || isPrefixOperator(tokens, index, left, syntax) ? 0 : 1;
		if (right == TokenKind.LeftBracket && left != TokenKind.Colon && left != TokenKind.Comma
			&& left != TokenKind.LeftBrace)
			return endsOperand(tokens, index, left, syntax) || isPrefixOperator(tokens, index, left, syntax) ? 0 : 1;
		if (left == TokenKind.Greater
			&& closesTypeArguments(tokens, index, syntax)
			&& (right == TokenKind.LeftParen || right == TokenKind.LeftBracket || right == TokenKind.Dot
			|| right == TokenKind.Comma
			|| right == TokenKind.Semicolon || right == TokenKind.RightParen || right == TokenKind.RightBracket
			|| right == TokenKind.RightBrace
			|| right == TokenKind.Greater))
			return 0;
		if (left == TokenKind.LeftBrace)
			return 0;
		if (right == TokenKind.LeftBrace)
			return 1;
		if (left == TokenKind.Comma)
			return 1;
		if (left == TokenKind.Colon)
			return syntax.roles.spacedColons.exists(tokens[index].start) ? 1 : 0;
		// An old-style function type is written tight (`Int->Void`); a lambda and a new-style function type (`(a:Int) -> Void`) are not.
		if (left == TokenKind.Arrow || right == TokenKind.Arrow) {
			var arrow = left == TokenKind.Arrow ? index : index + 1;
			return syntax.roles.tightArrows.exists(tokens[arrow].start) ? 0 : 1;
		}
		if (right == TokenKind.Colon)
			return syntax.roles.ternaryColons.exists(tokens[index + 1].start) ? 1 : 0;
		if (left == TokenKind.At || left == TokenKind.Backslash)
			return 0;
		if (left == TokenKind.Question && !syntax.roles.ternaryQuestions.exists(tokens[index].start))
			return 0;
		// Adjacent unary signs must not become an update token when the source is scanned again.
		if ((left == TokenKind.Plus && right == TokenKind.Plus)
			|| (left == TokenKind.Minus && right == TokenKind.Minus))
			return 1;
		if (right == TokenKind.Increment || right == TokenKind.Decrement)
			return endsOperand(tokens, index, left, syntax) || left == TokenKind.Not
				|| left == TokenKind.BitNot ? 0 : 1;
		if (left == TokenKind.Increment || left == TokenKind.Decrement)
			return index == 0
				|| !endsOperand(tokens, index - 1, FormatTokenTools.syntaxKind(tokens[index - 1]), syntax) ? 0 : 1;
		if (left == TokenKind.Not || left == TokenKind.BitNot)
			return 0;
		if ((syntax.roles.unarySigns.exists(tokens[index].start)))
			return 0;
		return 1;
	}



	static function opensTypeArguments(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Bool
		return index >= 0 && index < tokens.length && syntax.typeArgumentOpens.exists(tokens[index].start);

	static function closesTypeArguments(tokens:Array<FormatToken>, index:Int, syntax:SyntaxInfo):Bool
		return index >= 0 && index < tokens.length && syntax.typeArgumentCloses.exists(tokens[index].start);

	/** Can this token end an operand, so that a following `(` or `[` is a call or an index rather than a new expression? */
	static function endsOperand(tokens:Array<FormatToken>, index:Int, kind:Null<TokenKind>, syntax:SyntaxInfo):Bool
		return switch kind {
			case TokenKind.Identifier, TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace,
				TokenKind.This, TokenKind.New, TokenKind.Function,
				TokenKind.StringLiteral, TokenKind.Integer, TokenKind.Float, TokenKind.BoolTrue, TokenKind.BoolFalse,
				TokenKind.TypeInt, TokenKind.TypeBool,
				TokenKind.TypeFloat, TokenKind.TypeString, TokenKind.Dollar:
				true;
			case TokenKind.Greater:
				closesTypeArguments(tokens, index, syntax);
			default:
				false;
		};

	/** A prefix operator binds to what follows it without a space: `!(a)`, `-(a)`, `@:meta`. */
	static function isPrefixOperator(tokens:Array<FormatToken>, index:Int, kind:Null<TokenKind>, syntax:SyntaxInfo):Bool
		return kind == TokenKind.Not || kind == TokenKind.BitNot || kind == TokenKind.Increment
			|| kind == TokenKind.Decrement || kind == TokenKind.At
			|| kind == TokenKind.Backslash || (syntax.roles.unarySigns.exists(tokens[index].start));




	static function isComparisonOperator(kind:TokenKind):Bool
		return kind == TokenKind.LessEqual || kind == TokenKind.GreaterEqual || kind == TokenKind.EqualEqual
			|| kind == TokenKind.NotEqual
			|| kind == TokenKind.Less || kind == TokenKind.Greater;

	static function isLogicalOperator(kind:TokenKind):Bool
		return kind == TokenKind.AndAnd || kind == TokenKind.OrOr;

	static function isArithmeticOperator(kind:TokenKind):Bool
		return kind == TokenKind.Plus || kind == TokenKind.Minus || kind == TokenKind.Star || kind == TokenKind.Slash
			|| kind == TokenKind.Percent
			|| kind == TokenKind.Ampersand || kind == TokenKind.Pipe || kind == TokenKind.Caret
			|| kind == TokenKind.NullCoalesce;

	static function flatWidth(line:UnwrappedLine, config:FormatConfig, syntax:SyntaxInfo):Int
		return line.indent * config.indentWidth + rangeWidth(line, 0, line.tokens.length - 1, syntax);

	/** The width of the line before the group's opening token, given which enclosing groups are already split one element per line. */
	static function groupPrefixWidth(line:UnwrappedLine, breakable:Array<Bool>, open:Int,
			expanded:Array<DelimiterGroup>, indent:Int, config:FormatConfig,
			syntax:SyntaxInfo):Int {
		var start = lineStart(line, breakable, open, expanded, indent, config);
		return start.indent * config.indentWidth
			+ (open == start.token ? 0 : rangeWidth(line, start.token, open - 1, syntax)
			+ spacing(line.tokens, open - 1, FormatTokenTools.syntaxKind(line.tokens[open - 1]),
			FormatTokenTools.syntaxKind(line.tokens[open]), syntax));
	}

	/**
	 * The first token of the line holding `open` and that line's indent: the element of the innermost expanded group around it, or
	 * the statement, moved on to the last line its author began before `open` at the same bracket level (that break is kept).
	 */
	static function lineStart(line:UnwrappedLine, breakable:Array<Bool>, open:Int, expanded:Array<DelimiterGroup>,
			indent:Int, config:FormatConfig): {
				token: Int,
				indent: Int
			} {
		var parent:Null<DelimiterGroup> = null;
		for (group in expanded)
			if (group.open < open && open < group.close && (parent == null || group.open > parent.open))
				parent = group;
		var token = 0, startIndent = indent;
		if (parent != null) {
			token = parent.open + 1;
			for (comma in parent.commas)
				if (comma < open)
					token = comma + 1;
			startIndent = lineStart(line, breakable, parent.open, expanded, indent,
				config).indent + FormatConfigTools.continuationLevels(config);
		}
		var depth = 0, authored = -1;
		for (index in token...open) {
			switch FormatTokenTools.syntaxKind(line.tokens[index]) {
				case TokenKind.LeftParen | TokenKind.LeftBracket | TokenKind.LeftBrace:
					depth++;
				case TokenKind.RightParen | TokenKind.RightBracket | TokenKind.RightBrace:
					depth--;
				default:
			}
			// Only where a break may go: a line its author began elsewhere is joined, so it does not start the group's line.
			if (index > token && depth == 0 && breakable[index - 1]
				&& UnwrappedLineTools.beganSourceLine(line, line.tokens[index]))
				authored = index;
		}
		if (authored > 0)
			return {token: authored, indent: startIndent + FormatConfigTools.continuationLevels(config)};
		return {token: token, indent: startIndent};
	}

	/** The flat width of tokens `start` to `end`, trailing comments (and the space before them) not counted. */
	static function rangeWidth(line:UnwrappedLine, start:Int, end:Int, syntax:SyntaxInfo):Int {
		var tokens = line.tokens;
		if (start > end)
			return 0;
		var width = 0;
		for (index in start...end + 1) {
			if (UnwrappedLineTools.isTrailingComment(line, tokens[index]))
				continue;
			if (index > start)
				width += spacing(tokens, index - 1, FormatTokenTools.syntaxKind(tokens[index - 1]),
					FormatTokenTools.syntaxKind(tokens[index]), syntax);
			width += tokens[index].text.length;
		}
		return width;
	}

	static function addSpaces(output:StringBuf, count:Int):Void
		for (_ in 0...count)
			output.add(" ");
}
