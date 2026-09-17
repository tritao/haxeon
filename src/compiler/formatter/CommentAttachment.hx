package compiler.formatter;

import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;

/** The syntactic neighbor a comment should travel with during layout. */
enum CommentAttachmentKind {
	Leading(nextToken:Int);
	Trailing(previousToken:Int);
	Standalone;
}

/** Comment attachment information keyed by the comment's token index. */
typedef CommentAttachments = Map<Int, CommentAttachmentKind>;

/** Attaches comments before physical layout, without rewriting their contents. */
class CommentAttachmentTools {
	public static function attach(tokens:Array<FormatToken>):CommentAttachments {
		var result:CommentAttachments = [],
			previousSyntax:Null<Int> = null,
			nextSyntax:Array<Null<Int>> = [];
		var next:Null<Int> = null, index = tokens.length - 1;
		while (index >= 0) {
			nextSyntax[index] = next;
			if (FormatTokenTools.isSyntax(tokens[index]))
				next = index;
			index--;
		}
		for (index in 0...tokens.length) {
			var token = tokens[index];
			switch token.kind {
				case FormatTokenKind.LineComment, FormatTokenKind.BlockComment, FormatTokenKind.DocComment:
					var previous = previousSyntax,
						nextToken = nextSyntax[index],
						lineBreakBefore = hasNewline(tokens, previous, index),
						lineBreakAfter = hasNewline(tokens, index, nextToken);
					if (token.kind == FormatTokenKind.DocComment && nextToken != null)
						result.set(index, CommentAttachmentKind.Leading(nextToken));
					else if (previous != null && !lineBreakBefore)
						result.set(index, CommentAttachmentKind.Trailing(previous));
					else if (nextToken != null && (lineBreakAfter || token.kind == FormatTokenKind.BlockComment))
						result.set(index, CommentAttachmentKind.Leading(nextToken));
					else
						result.set(index, CommentAttachmentKind.Standalone);
				default:
			}
			if (FormatTokenTools.isSyntax(token))
				previousSyntax = index;
		}
		return result;
	}

	static function hasNewline(tokens:Array<FormatToken>, start:Null<Int>, end:Null<Int>):Bool {
		if (start == null || end == null)
			return false;
		for (index in start + 1...end + 1)
			if (FormatTokenTools.hasNewline(tokens[index]))
				return true;
		return false;
	}
}
