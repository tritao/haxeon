package compiler.formatter;

import compiler.Source.SourceFile;
import compiler.syntax.SyntaxScanner;
import compiler.syntax.SyntaxScanner.LosslessToken;
import compiler.syntax.SyntaxScanner.SyntaxTokenKind;
import compiler.formatter.FormatToken.FormatTokenKind;

private typedef ProtectedRange = {
	final start:Int;
	final end:Int;
}

/**
	Formatter adapter over the shared lossless scanner.

	Formatter-only policies such as formatter-off regions remain here, while
	literal, comment, identifier, number, and punctuation recognition belongs to
	SyntaxScanner.
 */
class FormatScanner {
	final file:SourceFile;

	public function new(file:SourceFile)
		this.file = file;

	/** Returns formatter tokens whose text concatenates byte-for-byte to input. */
	public function scan():Array<FormatToken> {
		var syntaxTokens = new SyntaxScanner(file).scan(),
			ranges = findFormatterOffRanges(syntaxTokens),
			result:Array<FormatToken> = [],
			cursor = 0;
		for (range in ranges) {
			append(syntaxTokens, cursor, range.start, result);
			push(result, FormatTokenKind.FormatterOff, range.start, range.end);
			cursor = range.end;
		}
		append(syntaxTokens, cursor, file.bytes.length, result);
		return result;
	}

	/** The scanner's fundamental losslessness oracle. */
	public function roundTrip(tokens:Array<FormatToken>):String {
		var output = new StringBuf();
		for (token in tokens)
			output.add(token.text);
		return output.toString();
	}

	function append(tokens:Array<LosslessToken>, start:Int, end:Int, result:Array<FormatToken>):Void {
		if (end <= start)
			return;
		for (token in tokens) {
			if (token.span.end <= start)
				continue;
			if (token.span.start >= end)
				break;
			var sliceStart = token.span.start < start ? start : token.span.start,
				sliceEnd = token.span.end > end ? end : token.span.end;
			if (sliceEnd > sliceStart)
				push(result, formatKind(token.kind), sliceStart, sliceEnd);
		}
	}

	function formatKind(kind:SyntaxTokenKind):FormatTokenKind
		return switch kind {
			case SyntaxTokenKind.Syntax(kind): FormatTokenKind.Syntax(kind);
			case SyntaxTokenKind.Whitespace: FormatTokenKind.Whitespace;
			case SyntaxTokenKind.Newline: FormatTokenKind.Newline;
			case SyntaxTokenKind.LineComment: FormatTokenKind.LineComment;
			case SyntaxTokenKind.BlockComment: FormatTokenKind.BlockComment;
			case SyntaxTokenKind.DocComment: FormatTokenKind.DocComment;
			case SyntaxTokenKind.Directive: FormatTokenKind.Directive;
			case SyntaxTokenKind.Unknown: FormatTokenKind.Whitespace;
		};

	function findFormatterOffRanges(tokens:Array<LosslessToken>):Array<ProtectedRange> {
		var markers:Array<{offset:Int, off:Bool}> = [];
		for (token in tokens)
			switch token.kind {
				case SyntaxTokenKind.LineComment, SyntaxTokenKind.BlockComment, SyntaxTokenKind.DocComment:
					collectMarkers(token, markers);
				default:
			}
		markers.sort(function(left, right) return left.offset - right.offset);
		var result:Array<ProtectedRange> = [], protectedStart = -1;
		for (marker in markers) {
			if (marker.off) {
				if (protectedStart < 0)
					protectedStart = lineStart(marker.offset);
			} else if (protectedStart >= 0) {
				result.push({start: protectedStart, end: lineEnd(marker.offset)});
				protectedStart = -1;
			}
		}
		if (protectedStart >= 0)
			result.push({start: protectedStart, end: file.bytes.length});
		return result;
	}

	function collectMarkers(token:LosslessToken, result:Array<{offset:Int, off:Bool}>):Void {
		var text = token.text, index = 0;
		while (index < text.length) {
			var offIndex = text.indexOf("@formatter:off", index),
				onIndex = text.indexOf("@formatter:on", index);
			if (offIndex < 0 && onIndex < 0)
				return;
			if (onIndex < 0 || offIndex >= 0 && offIndex < onIndex) {
				result.push({offset: token.span.start + offIndex, off: true});
				index = offIndex + "@formatter:off".length;
			} else {
				result.push({offset: token.span.start + onIndex, off: false});
				index = onIndex + "@formatter:on".length;
			}
		}
	}

	function lineStart(offset:Int):Int {
		var cursor = offset;
		while (cursor > 0 && file.bytes.get(cursor - 1) != "\n".code)
			cursor--;
		return cursor;
	}

	function lineEnd(offset:Int):Int {
		var cursor = offset;
		while (cursor < file.bytes.length && file.bytes.get(cursor) != "\r".code && file.bytes.get(cursor) != "\n".code)
			cursor++;
		return cursor;
	}

	function push(result:Array<FormatToken>, kind:FormatTokenKind, start:Int, end:Int):Void
		if (end > start)
			result.push({kind: kind, text: file.slice(start, end), start: start, end: end});

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
}
