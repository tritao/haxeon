package compiler.formatter;

import compiler.Diagnostic.CompileError;
import compiler.Source.SourceFile;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.SyntaxTree.ParserMode;
import compiler.syntax.SyntaxTree.SyntaxTree;
import compiler.formatter.SyntaxAnnotator.SyntaxInfo;
import compiler.formatter.UnwrappedLine.UnwrappedLineBuilder;
import compiler.formatter.CommentAttachment.CommentAttachmentTools;
import compiler.formatter.FormatToken.FormatTokenTools;

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

/** Token/CST formatter facade. Parser validation remains the refusal boundary. */
class Formatter {
	public static function format(source:String, config:FormatConfig, ?rangeStart:Int, ?rangeEnd:Int):Null<String> {
		var file = new SourceFile("<format>", source);
		try {
			var conditional = ConditionalCompilation.process(file, []);
			var parser = new Parser(new Lexer(file, conditional.text).tokenize(), null, ParserMode.Cst(file));
			parser.parseProgram();
			var syntaxTree:Null<SyntaxTree> = parser.cst;
			var tokens = new FormatScanner(file).scan(),
				comments = CommentAttachmentTools.attach(tokens),
				syntax = SyntaxAnnotator.annotate(tokens, syntaxTree),
				units = UnwrappedLineBuilder.build(tokens, syntax, comments),
				rendered = [for (unit in units) renderUnit(unit, syntax, config)],
				newline = source.indexOf("\r\n") >= 0 ? "\r\n" : "\n";
			if (rangeStart == null || rangeEnd == null)
				return joinRendered(rendered, newline, StringTools.endsWith(source, "\n"));
			if (rangeStart <= 0 && rangeEnd >= source.length)
				return joinRendered(rendered, newline, StringTools.endsWith(source, "\n"));
			return formatRange(file, tokens, syntax, units, rendered, newline, rangeStart, rangeEnd);
		} catch (_:CompileError) {
			return null;
		} catch (_:Dynamic) {
			return null;
		}
	}

	static function renderUnit(unit:UnwrappedLine, syntax:SyntaxInfo, config:FormatConfig):RenderedUnit {
		var boundaries = BreakAnalyzer.analyze(unit, syntax, config),
			layout = LayoutSolver.solve(unit, boundaries, config);
		return {
			sourceStart: unit.sourceStart,
			sourceEnd: unit.sourceEnd,
			blankBefore: unit.blankBefore,
			lines: Renderer.render(unit, layout, boundaries, config)
		};
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

	static function formatRange(file:SourceFile, tokens:Array<FormatToken>, syntax:SyntaxInfo, units:Array<UnwrappedLine>, rendered:Array<RenderedUnit>,
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
			&& selectedUnit != null ? expandRange(tokens, syntax, start, end, selectedUnit.sourceStart, selectedUnit.sourceEnd) : {
				start: start,
				end: end
			},
			selectedLines:Map<Int, Bool> = [];
		start = region.start;
		end = region.end;
		for (index in 0...units.length) {
			var unit = units[index],
				intersects = rangeStart == rangeEnd ? unit.sourceStart <= start && unit.sourceEnd >= start : unit.sourceEnd > start && unit.sourceStart < end;
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
			var unit = units[index], first = file.lineAt(unit.sourceStart) - 1,
				last = file.lineAt(unit.sourceEnd > unit.sourceStart ? unit.sourceEnd - 1 : unit.sourceEnd) - 1, shares = false;
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
	static function expandRange(tokens:Array<FormatToken>, syntax:SyntaxInfo, start:Int, end:Int, safeStart:Int, safeEnd:Int):{start:Int, end:Int} {
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
