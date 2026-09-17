package compiler.formatter;

import compiler.Source.SourceFile;
import compiler.syntax.SyntaxTree.SyntaxElement;
import compiler.syntax.SyntaxTree.SyntaxNode;
import compiler.syntax.SyntaxTree.SyntaxToken;
import compiler.syntax.SyntaxTree.SyntaxTrivia;
import compiler.syntax.SyntaxTree.SyntaxTriviaKind;
import compiler.syntax.SyntaxTree.SyntaxTree;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;

private typedef ProtectedRange = {
	final start:Int;
	final end:Int;
}

/**
	Builds formatter tokens from the optional lossless CST.

	The CST owns source leaves and trivia in tooling mode, so the formatter no
	longer needs a second scanner to reconstruct the same byte stream. Formatter
	off/on remains a formatter policy and is represented as one opaque token for
	the existing layout pipeline.
*/
class CstFormatterAdapter {
	public static function tokens(tree:SyntaxTree):Array<FormatToken> {
		var leaves = sourceLeaves(tree.root),
			ranges = findFormatterOffRanges(tree.source, leaves),
			result:Array<FormatToken> = [],
			cursor = 0;
		for (range in ranges) {
			append(leaves, tree.source, cursor, range.start, result);
			push(result, tree.source, FormatTokenKind.FormatterOff, range.start, range.end);
			cursor = range.end;
		}
		append(leaves, tree.source, cursor, tree.source.bytes.length, result);
		return result;
	}

	public static function roundTrip(tokens:Array<FormatToken>):String {
		var output = new StringBuf();
		for (token in tokens)
			output.add(token.text);
		return output.toString();
	}

	/**
		Returns the smallest parser-reported source region containing a partial
		range. The result is constrained to the logical formatter unit so range
		formatting cannot escape its already selected statement/declaration.
	*/
	public static function smallestEnclosing(tree:SyntaxTree, tokens:Array<FormatToken>, start:Int, end:Int, safeStart:Int,
			safeEnd:Int):Null<{start:Int, end:Int}> {
		var firstSyntax = -1, lastSyntax = -1;
		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index]) && tokens[index].end > start && tokens[index].start < end) {
				if (firstSyntax < 0)
					firstSyntax = index;
				lastSyntax = index;
			}
		if (firstSyntax < 0)
			return null;

		var selectedStart = safeStart,
			selectedEnd = safeEnd,
			selectedWidth = safeEnd - safeStart,
			firstStart = tokens[firstSyntax].start,
			lastEnd = tokens[lastSyntax].end;
		for (node in tree.grammarNodes()) {
			var nodeStart = node.span.start, nodeEnd = node.span.end,
				width = nodeEnd - nodeStart;
			if (nodeStart < safeStart || nodeEnd > safeEnd || nodeStart > firstStart || nodeEnd < lastEnd || width >= selectedWidth)
				continue;
			selectedStart = nodeStart;
			selectedEnd = nodeEnd;
			selectedWidth = width;
		}
		return selectedStart == safeStart && selectedEnd == safeEnd ? null : {start: selectedStart, end: selectedEnd};
	}

	/** Returns the directive keyword without its condition or surrounding trivia. */
	public static function directiveName(text:String):String {
		var index = 0;
		while (index < text.length
			&& (text.charCodeAt(index) == "#".code || text.charCodeAt(index) == " ".code || text.charCodeAt(index) == "\t".code
				|| text.charCodeAt(index) == "\r".code))
			index++;
		var start = index;
		while (index < text.length) {
			var code = text.charCodeAt(index);
			if (code == " ".code || code == "\t".code || code == "\r".code || code == "(".code)
				break;
			index++;
		}
		return text.substring(start, index);
	}

	static function sourceLeaves(node:SyntaxNode):Array<{kind:FormatTokenKind, start:Int, end:Int}> {
		var result:Array<{kind:FormatTokenKind, start:Int, end:Int}> = [];
		for (element in node.children)
			switch element {
				case SyntaxElement.Token(token):
					if (!token.synthetic)
						result.push({kind: FormatTokenKind.Syntax(token.kind), start: token.span.start, end: token.span.end});
				case SyntaxElement.Trivia(trivia):
					result.push({kind: triviaKind(trivia), start: trivia.span.start, end: trivia.span.end});
				case SyntaxElement.Node(value):
					appendNodeLeaves(value, result);
			}
		return result;
	}

	static function appendNodeLeaves(node:SyntaxNode, result:Array<{kind:FormatTokenKind, start:Int, end:Int}>):Void {
		for (element in node.children)
			switch element {
				case SyntaxElement.Token(token):
					if (!token.synthetic)
						result.push({kind: FormatTokenKind.Syntax(token.kind), start: token.span.start, end: token.span.end});
				case SyntaxElement.Trivia(trivia):
					result.push({kind: triviaKind(trivia), start: trivia.span.start, end: trivia.span.end});
				case SyntaxElement.Node(value):
					appendNodeLeaves(value, result);
			}
	}

	static function triviaKind(trivia:SyntaxTrivia):FormatTokenKind
		return switch trivia.kind {
			case SyntaxTriviaKind.Whitespace: FormatTokenKind.Whitespace;
			case SyntaxTriviaKind.Newline: FormatTokenKind.Newline;
			case SyntaxTriviaKind.LineComment: FormatTokenKind.LineComment;
			case SyntaxTriviaKind.BlockComment: FormatTokenKind.BlockComment;
			case SyntaxTriviaKind.DocComment: FormatTokenKind.DocComment;
			case SyntaxTriviaKind.Directive: FormatTokenKind.Directive;
			case SyntaxTriviaKind.Unknown: FormatTokenKind.Whitespace;
		};

	static function findFormatterOffRanges(file:SourceFile, leaves:Array<{kind:FormatTokenKind, start:Int, end:Int}>):Array<ProtectedRange> {
		var markers:Array<{offset:Int, off:Bool}> = [];
		for (leaf in leaves)
			switch leaf.kind {
				case FormatTokenKind.LineComment, FormatTokenKind.BlockComment, FormatTokenKind.DocComment:
					collectMarkers(file, leaf, markers);
				default:
			}
		markers.sort(function(left, right) return left.offset - right.offset);
		var result:Array<ProtectedRange> = [], protectedStart = -1;
		for (marker in markers) {
			if (marker.off) {
				if (protectedStart < 0)
					protectedStart = lineStart(file, marker.offset);
			} else if (protectedStart >= 0) {
				result.push({start: protectedStart, end: lineEnd(file, marker.offset)});
				protectedStart = -1;
			}
		}
		if (protectedStart >= 0)
			result.push({start: protectedStart, end: file.bytes.length});
		return result;
	}

	static function collectMarkers(file:SourceFile, leaf:{kind:FormatTokenKind, start:Int, end:Int}, result:Array<{offset:Int, off:Bool}>):Void {
		var text = file.slice(leaf.start, leaf.end), index = 0;
		while (index < text.length) {
			var offIndex = text.indexOf("@formatter:off", index),
				onIndex = text.indexOf("@formatter:on", index);
			if (offIndex < 0 && onIndex < 0)
				return;
			if (onIndex < 0 || offIndex >= 0 && offIndex < onIndex) {
				result.push({offset: leaf.start + offIndex, off: true});
				index = offIndex + "@formatter:off".length;
			} else {
				result.push({offset: leaf.start + onIndex, off: false});
				index = onIndex + "@formatter:on".length;
			}
		}
	}

	static function append(leaves:Array<{kind:FormatTokenKind, start:Int, end:Int}>, file:SourceFile, start:Int, end:Int,
			result:Array<FormatToken>):Void {
		if (end <= start)
			return;
		for (leaf in leaves) {
			if (leaf.end <= start)
				continue;
			if (leaf.start >= end)
				break;
			var sliceStart = leaf.start < start ? start : leaf.start,
				sliceEnd = leaf.end > end ? end : leaf.end;
			if (sliceEnd > sliceStart)
				push(result, file, leaf.kind, sliceStart, sliceEnd);
		}
	}

	static function push(result:Array<FormatToken>, file:SourceFile, kind:FormatTokenKind, start:Int, end:Int):Void
		if (end > start)
			result.push({kind: kind, text: file.slice(start, end), start: start, end: end});

	static function lineStart(file:SourceFile, offset:Int):Int {
		var cursor = offset;
		while (cursor > 0 && file.bytes.get(cursor - 1) != "\n".code)
			cursor--;
		return cursor;
	}

	static function lineEnd(file:SourceFile, offset:Int):Int {
		var cursor = offset;
		while (cursor < file.bytes.length && file.bytes.get(cursor) != "\r".code && file.bytes.get(cursor) != "\n".code)
			cursor++;
		return cursor;
	}
}
