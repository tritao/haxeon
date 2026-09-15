package compiler.formatter;

import compiler.formatter.FormatDoc.FormatDocTools;
import compiler.formatter.FormatToken.FormatTokenTools;
import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.syntax.Token.TokenKind;

typedef LayoutLine = {
	final start:Int;
	final end:Int;
	final indent:Int;
}

typedef LineLayout = {
	final lines:Array<LayoutLine>;
	final cost:Int;
}

private typedef LayoutPath = {
	final cost:Int;
	final lines:Array<LayoutLine>;
}

/** Dynamic-programming line breaker over the annotated break opportunities. */
class LayoutSolver {
	public static function solve(line:UnwrappedLine, boundaries:Array<Boundary>, config:FormatConfig):LineLayout {
		if (line.tokens.length == 0)
			return {lines: [], cost: 0};
		var document = FormatDocTools.fromLine(line, boundaries),
			hasHardBreak = false;
		for (boundary in boundaries)
			if (boundary.mustBreak) {
				hasHardBreak = true;
				break;
			}
		if (!hasHardBreak && line.indent * config.indentWidth + FormatDocTools.flatLength(document) <= config.lineWidth)
			return {lines: [{start: 0, end: line.tokens.length - 1, indent: line.indent}], cost: 0};
		var memo:Map<String, LayoutPath> = [];

		function renderWidth(start:Int, end:Int):Int {
			var width = 0;
			for (index in start...end + 1) {
				if (index > start)
					width += boundaries[index - 1].spaces;
				width += line.tokens[index].text.length;
			}
			return width;
		}

		function solveFrom(start:Int, indent:Int):LayoutPath {
			var key = start + ":" + indent;
			if (memo.exists(key))
				return memo.get(key);
			var best:Null<LayoutPath> = null;
			for (end in start...line.tokens.length) {
				var width = renderWidth(start, end),
					columns = indent * config.indentWidth + width,
					overflow = columns > config.lineWidth ? columns - config.lineWidth : 0,
					localCost = overflow > 0 ? 1000 * overflow * overflow : 0;
				if (end == line.tokens.length - 1) {
					var terminal:LayoutPath = {cost: localCost, lines: [{start: start, end: end, indent: indent}]};
					best = choose(best, terminal);
					break;
				}
				var boundary = boundaries[end];
				if (boundary.mustBreak || boundary.canBreak) {
					var next = solveFrom(end + 1, continuationIndent(line, end, indent, boundary, config)),
						combined:Array<LayoutLine> = [{start: start, end: end, indent: indent}];
					combined = combined.concat(next.lines);
					var candidate:LayoutPath = {
						cost: localCost + boundary.penalty + next.cost,
						lines: combined
					};
					best = choose(best, candidate);
				}
				if (boundary.mustBreak)
					break;
			}
			if (best == null)
				best = {cost: 1000000000, lines: [{start: start, end: line.tokens.length - 1, indent: indent}]};
			memo.set(key, best);
			return best;
		}

		var result = solveFrom(0, line.indent);
		return {lines: result.lines, cost: result.cost};
	}

	static function choose(current:Null<LayoutPath>, candidate:LayoutPath):LayoutPath {
		if (current == null || candidate.cost < current.cost)
			return candidate;
		return current;
	}

	static function continuationIndent(line:UnwrappedLine, boundaryIndex:Int, currentIndent:Int, boundary:Boundary, config:FormatConfig):Int {
		var nextKind = FormatTokenTools.syntaxKind(line.tokens[boundaryIndex + 1]),
			leftKind = FormatTokenTools.syntaxKind(line.tokens[boundaryIndex]);
		if (nextKind == TokenKind.RightParen || nextKind == TokenKind.RightBracket || nextKind == TokenKind.RightBrace)
			return currentIndent > line.indent ? currentIndent - 1 : boundary.continuationIndent;
		if (boundary.mustBreak
			&& (leftKind == TokenKind.LeftParen || leftKind == TokenKind.LeftBracket || leftKind == TokenKind.Less)
			&& currentIndent > line.indent)
			return currentIndent + FormatConfigTools.continuationLevels(config);
		if (boundary.mustBreak && leftKind == TokenKind.Comma && currentIndent > line.indent)
			return currentIndent;
		return boundary.continuationIndent;
	}
}
