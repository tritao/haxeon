package compiler.formatter;

import compiler.formatter.Boundary.BreakLayout;
import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.FormatDoc.FormatDocTools;
import compiler.formatter.FormatToken.FormatTokenTools;
import compiler.formatter.UnwrappedLine.UnwrappedLineTools;
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

		// A comment that trails code is not measured: it stays on its line whatever the width (BreakAnalyzer), so counting it would only
		// make the solver break the code before it to make room it cannot get.
		function renderWidth(start:Int, end:Int):Int {
			var width = 0;
			for (index in start...end + 1) {
				var token = line.tokens[index];
				if (UnwrappedLineTools.isTrailingComment(line, token))
					continue;
				if (index > start)
					width += boundaries[index - 1].spaces;
				width += token.text.length;
			}
			return width;
		}

		// `indent` is the current physical line's, `base` the indent of the element it belongs to (see BreakLayout).
		function solveFrom(start:Int, indent:Int, base:Int):LayoutPath {
			var key = start + ":" + indent + ":" + base;
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
					var placed = place(boundary.layout, indent, base, line, config),
						next = solveFrom(end + 1, placed.indent, placed.base),
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

		var result = solveFrom(0, line.indent, line.indent);
		return {lines: result.lines, cost: result.cost};
	}

	/** The cheaper layout; on a tie the one found later, which breaks later, so a wrapped list fills its first line. */
	static function choose(current:Null<LayoutPath>, candidate:LayoutPath):LayoutPath {
		if (current == null || candidate.cost <= current.cost)
			return candidate;
		return current;
	}

	/** The indent of the line after a break, and of the element it starts. */
	static function place(layout:BreakLayout, indent:Int, base:Int, line:UnwrappedLine, config:FormatConfig): {
		indent: Int,
		base: Int
	} {
		var levels = FormatConfigTools.continuationLevels(config);
		return switch layout {
			case Wrap(count): {indent: base + count * levels, base: base};
			case Open: {indent: indent + levels, base: indent + levels};
			case Separator: {indent: base, base: base};
			case Close:
				var closing = Std.int(Math.max(line.indent, base - levels));
				{
					indent:closing, base:closing
				};
			case At(fixed): {indent: fixed, base: fixed};
		};
	}
}
