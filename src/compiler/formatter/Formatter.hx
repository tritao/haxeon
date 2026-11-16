package compiler.formatter;

import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceFile;
import compiler.formatter.CommentAttachment.CommentAttachmentTools;
import compiler.formatter.FormatToken.FormatTokenTools;
import compiler.formatter.SyntaxAnnotator.SyntaxInfo;
import compiler.formatter.UnwrappedLine.UnwrappedLineBuilder;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Lexer;
import compiler.syntax.Token;
import compiler.syntax.Token.TokenKind;

private typedef RenderedUnit = {
	final sourceStart:Int;
	final sourceEnd:Int;
	final blankBefore:Int;
	final lines:Array<String>;
}

private typedef Replacement = {
	final start:Int;
	final end:Int;
	final text:String;
}

/**
 * Token/CST formatter facade. It formats any source that lexes and whose brackets balance, including Haxe that Haxeon's parser does
 * not accept yet (stock-Haxe tools in this repository use rest arguments, `using`, untyped catches, quoted object fields): the layout
 * works on tokens, and TokenPreservation refuses any output whose tokens or comments differ from the input. Unbalanced brackets, as
 * in code being typed, are refused, since their layout would only confuse.
 */
class Formatter {
	public static function format(source:String, config:FormatConfig, ?rangeStart:Int, ?rangeEnd:Int,
			?path:String):Null<String> {
		var file = new SourceFile(path == null ? "<format>" : path, source);
		var result:String;
		try {
			var conditional = ConditionalCompilation.process(file, []);
			requireBalanced(new Lexer(file, conditional.text).tokenize());
			var tokens = TypeArguments.splitAssignments(new FormatScanner(file).scan()),
				comments = CommentAttachmentTools.attach(tokens),
				syntax = SyntaxAnnotator.annotate(tokens),
				units = UnwrappedLineBuilder.build(tokens, syntax, comments),
				rendered = renderUnits(units, tokens, syntax, config),
				newline = source.indexOf("\r\n") >= 0 ? "\r\n" : "\n";
			if (rangeStart == null || rangeEnd == null || rangeStart <= 0 && rangeEnd >= source.length)
				result = joinRendered(rendered, newline, StringTools.endsWith(source, "\n"));
			else
				result = formatRange(file, tokens, syntax, units, rendered, newline, rangeStart, rangeEnd);
		} catch (_:CompileError) {
			return null;
		} catch (_:Dynamic) {
			return null;
		}
		TokenPreservation.verify(file.path, source, result);
		return result;
	}

	/** Throws unless every bracket closes the one opened last; conditional branches not taken are already blanked out. */
	static function requireBalanced(tokens:Array<Token>):Void {
		var open:Array<TokenKind> = [];
		for (token in tokens)
			switch token.kind {
				case LeftParen | LeftBrace | LeftBracket:
					open.push(token.kind);
				case RightParen | RightBrace | RightBracket:
					var expected = switch token.kind {
						case RightParen: LeftParen;
						case RightBrace: LeftBrace;
						default: LeftBracket;
					};
					if (open.length == 0 || open.pop() != expected)
						throw "unbalanced brackets";
				default:
			}
		if (open.length > 0)
			throw "unbalanced brackets";
	}

	/**
	 * Lays out every logical line in order. A block that opens at the end of a wrapped line (`value = if (c) {` on a continuation
	 * line, a callback passed as a later argument) indents its body from that physical line, not from its statement: the logical lines
	 * of the block inherit how far past its statement the opening line went, and its `}` lines up with that line. The line builder
	 * cannot know this; only the layout of the opening line does.
	 */
	static function renderUnits(units:Array<UnwrappedLine>, tokens:Array<FormatToken>, syntax:SyntaxInfo,
			config:FormatConfig):Array<RenderedUnit> {
		var indexAt = new Map<Int, Int>();
		for (index in 0...tokens.length)
			indexAt.set(tokens[index].start, index);
		// Open blocks whose opening line went past its statement: the start offset of each one's `}` and the extra levels inside it.
		var blocks:Array<{close:Int, extra:Int}> = [], rendered:Array<RenderedUnit> = [];
		for (unit in units) {
			var extra = blocks.length == 0 ? 0 : blocks[blocks.length - 1].extra,
				line:UnwrappedLine = extra == 0 ? unit : {
					tokens: unit.tokens,
					indent: unit.indent + extra,
					blankBefore: unit.blankBefore,
					sourceStart: unit.sourceStart,
					sourceEnd: unit.sourceEnd,
					trailingComments: unit.trailingComments,
					newlineBefore: unit.newlineBefore
				},
				boundaries = BreakAnalyzer.analyze(line, syntax, config),
				layout = LayoutSolver.solve(line, boundaries, config);
			rendered.push({
				sourceStart: unit.sourceStart,
				sourceEnd: unit.sourceEnd,
				blankBefore: unit.blankBefore,
				lines: Renderer.render(line, layout, boundaries, config)
			});
			// A `}` that begins this line closes its block; the line itself still lined up with the block's opener.
			var first = firstSyntax(unit);
			if (first != null && blocks.length > 0 && first.start == blocks[blocks.length - 1].close)
				blocks.pop();
			// A block left open at the end of this line indents its body from the line's last physical line.
			var last = lastSyntax(unit);
			if (last != null && FormatTokenTools.syntaxKind(last) == TokenKind.LeftBrace
				&& syntax.blockOpens.exists(last.start) && syntax.blockOpens.get(last.start)
				&& layout.lines.length > 0) {
				// A statement's own block (a function or control body) stays one level past the statement however its header wraps; a
				// block inside an expression lives where the expression's line is.
				if (!insideExpression(unit))
					continue;
				var open = indexAt.get(last.start),
					close = open == null ? null : syntax.matching.get(open),
					beyond = layout.lines[layout.lines.length - 1].indent - unit.indent;
				if (close != null && beyond > 0)
					blocks.push({close: tokens[close].start, extra: beyond});
				else if (close != null && extra > 0)
					// The block still sits inside an indented one: its lines keep that block's extra levels until it closes.
					blocks.push({close: tokens[close].start, extra: extra});
			}
		}
		return rendered;
	}

	/**
	 * Whether the `{` ending `unit` opens a block inside an expression: inside an unclosed bracket (a callback argument), or after
	 * `=`, `return`, `throw` or `->` at the line's top level (`value = if (c) {`, `x -> {`). Otherwise it is its statement's own.
	 */
	static function insideExpression(unit:UnwrappedLine):Bool {
		var depth = 0, expression = false, last = unit.tokens.length - 1;
		while (last >= 0 && !FormatTokenTools.isSyntax(unit.tokens[last]))
			last--;
		for (index in 0...last)
			switch FormatTokenTools.syntaxKind(unit.tokens[index]) {
				case TokenKind.LeftParen, TokenKind.LeftBracket, TokenKind.LeftBrace:
					depth++;
				case TokenKind.RightParen, TokenKind.RightBracket, TokenKind.RightBrace:
					depth--;
				case TokenKind.Assign, TokenKind.Return, TokenKind.Throw, TokenKind.Arrow if (depth == 0):
					expression = true;
				default:
			}
		return depth > 0 || expression;
	}

	static function firstSyntax(unit:UnwrappedLine):Null<FormatToken> {
		for (token in unit.tokens)
			if (FormatTokenTools.isSyntax(token))
				return token;
		return null;
	}

	static function lastSyntax(unit:UnwrappedLine):Null<FormatToken> {
		var index = unit.tokens.length - 1;
		while (index >= 0 && !FormatTokenTools.isSyntax(unit.tokens[index]))
			index--;
		return index >= 0 ? unit.tokens[index] : null;
	}

	static function joinRendered(units:Array<RenderedUnit>, newline:String, trailingNewline:Bool):String {
		if (units.length == 0)
			return trailingNewline ? newline : "";
		var output = new StringBuf(), first = true;
		for (unit in units) {
			if (!first)
				output.add(newline);
			for (_ in 0...unit.blankBefore)
				output.add(newline);
			for (index in 0...unit.lines.length) {
				if (index > 0)
					output.add(newline);
				output.add(unit.lines[index]);
			}
			first = false;
		}
		var result = output.toString();
		return trailingNewline ? result + newline : result;
	}

	static function formatRange(file:SourceFile, tokens:Array<FormatToken>, syntax:SyntaxInfo,
			units:Array<UnwrappedLine>, rendered:Array<RenderedUnit>,
			newline:String, rangeStart:Int, rangeEnd:Int):String {
		var start = file.byteOffsetForStringOffset(Std.int(Math.max(0, Math.min(file.text.length, rangeStart)))),
			end = file.byteOffsetForStringOffset(Std.int(Math.max(0, Math.min(file.text.length, rangeEnd)))),
			intersectingUnits = 0,
			selectedUnit:Null<UnwrappedLine> = null;
		for (unit in units)
			if (unit.sourceEnd > start && unit.sourceStart < end) {
				intersectingUnits++;
				selectedUnit = unit;
			}
		var region = intersectingUnits == 1
			&& selectedUnit != null ? expandRange(tokens, syntax, start, end, selectedUnit.sourceStart,
			selectedUnit.sourceEnd) : {
				start: start,
				end: end
			},
			selectedLines:Map<Int, Bool> = [];
		start = region.start;
		end = region.end;
		for (index in 0...units.length) {
			var unit = units[index],
				intersects = rangeStart == rangeEnd ? unit.sourceStart <= start
					&& unit.sourceEnd >= start : unit.sourceEnd > start && unit.sourceStart < end;
			if (!intersects)
				continue;
			var first = file.lineAt(unit.sourceStart) - 1,
				last = file.lineAt(unit.sourceEnd > unit.sourceStart ? unit.sourceEnd - 1 : unit.sourceEnd) - 1;
			for (line in first...last + 1)
				selectedLines.set(line, true);
		}
		if (!selectedLines.keys().hasNext())
			return file.text;

		// Formatting a physical line selects every logical unit sharing that line,
		// which expands partial ranges to a consistent statement/declaration.
		for (index in 0...units.length) {
			var unit = units[index],
				first = file.lineAt(unit.sourceStart) - 1,
				last = file.lineAt(unit.sourceEnd > unit.sourceStart ? unit.sourceEnd - 1 : unit.sourceEnd) - 1,
				shares = false;
			for (line in first...last + 1)
				if (selectedLines.exists(line)) {
					shares = true;
					break;
				}
			if (shares)
				for (line in first...last + 1)
					selectedLines.set(line, true);
		}

		var replacements:Array<Replacement> = [], line = 0;
		while (line < lineCount(file)) {
			if (!selectedLines.exists(line)) {
				line++;
				continue;
			}
			var firstLine = line;
			while (line + 1 < lineCount(file) && selectedLines.exists(line + 1))
				line++;
			var lastLine = line,
				replacement = new StringBuf(),
				firstUnit = true;
			for (unitIndex in 0...units.length) {
				var unit = units[unitIndex],
					unitFirst = file.lineAt(unit.sourceStart) - 1,
					unitLast = file.lineAt(unit.sourceEnd > unit.sourceStart ? unit.sourceEnd - 1 : unit.sourceEnd) - 1;
				if (unitLast < firstLine || unitFirst > lastLine)
					continue;
				if (!firstUnit) {
					replacement.add(newline);
					for (_ in 0...unit.blankBefore)
						replacement.add(newline);
				}
				for (lineIndex in 0...rendered[unitIndex].lines.length) {
					if (lineIndex > 0)
						replacement.add(newline);
					replacement.add(rendered[unitIndex].lines[lineIndex]);
				}
				firstUnit = false;
			}
			var startByte = lineStart(file, firstLine),
				endByte = lineContentEnd(file, lastLine);
			replacements.push({start: startByte, end: endByte, text: replacement.toString()});
			line++;
		}

		var output = new StringBuf(), cursor = 0;
		for (replacement in replacements) {
			output.add(file.slice(cursor, replacement.start));
			output.add(replacement.text);
			cursor = replacement.end;
		}
		output.add(file.slice(cursor, file.bytes.length));
		return output.toString();
	}

	/** Expands a partial range to the smallest annotated syntax region containing it. */
	static function expandRange(tokens:Array<FormatToken>, syntax:SyntaxInfo, start:Int, end:Int, safeStart:Int,
			safeEnd:Int):{
				start:Int,
				end:Int
			} {
		var firstSyntax = -1, lastSyntax = -1;
		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index]) && tokens[index].end > start && tokens[index].start < end) {
				if (firstSyntax < 0)
					firstSyntax = index;
				lastSyntax = index;
			}
		if (firstSyntax < 0)
			return {start: start, end: end};
		var selectedStart = safeStart,
			selectedEnd = safeEnd,
			selectedWidth = safeEnd - safeStart;
		for (node in syntax.nodes) {
			if (node.start < 0 || node.end >= tokens.length)
				continue;
			var nodeStart = tokens[node.start].start,
				nodeEnd = tokens[node.end].end;
			if (nodeStart >= safeStart
				&& nodeEnd <= safeEnd
				&& nodeStart <= tokens[firstSyntax].start
				&& nodeEnd >= tokens[lastSyntax].end) {
				var width = nodeEnd - nodeStart;
				if (width < selectedWidth) {
					selectedStart = nodeStart;
					selectedEnd = nodeEnd;
					selectedWidth = width;
				}
			}
		}
		return {start: selectedStart, end: selectedEnd};
	}

	static function lineCount(file:SourceFile):Int {
		var count = 1;
		for (index in 0...file.bytes.length)
			if (file.bytes.get(index) == "\n".code)
				count++;
		return count;
	}

	static function lineStart(file:SourceFile, line:Int):Int {
		if (line <= 0)
			return 0;
		var current = 0;
		for (index in 0...file.bytes.length)
			if (file.bytes.get(index) == "\n".code) {
				current++;
				if (current == line)
					return index + 1;
			}
		return file.bytes.length;
	}

	static function lineContentEnd(file:SourceFile, line:Int):Int {
		var start = lineStart(file, line), end = start;
		while (end < file.bytes.length && file.bytes.get(end) != "\n".code)
			end++;
		if (end > start && file.bytes.get(end - 1) == "\r".code)
			end--;
		return end;
	}
}
