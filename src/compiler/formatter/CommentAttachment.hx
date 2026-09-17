package compiler.formatter;

import compiler.Source.SourceFile;
import compiler.syntax.SyntaxTree.SyntaxTrivia;
import compiler.syntax.SyntaxTree.SyntaxTriviaKind;
import compiler.syntax.SyntaxTree.SyntaxTree;
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
	public static function attach(tokens:Array<FormatToken>, ?tree:SyntaxTree):CommentAttachments {
		return tree == null ? attachTokenStream(tokens) : attachCst(tokens, tree);
	}

	/** Uses CST trivia and source spans as the authoritative comment stream. */
	static function attachCst(tokens:Array<FormatToken>, tree:SyntaxTree):CommentAttachments {
		var comments:Map<Int, Bool> = [];
		for (trivia in tree.trivia)
			if (isComment(trivia.kind))
				comments.set(trivia.span.start, true);
		return attachWithNewlineSource(tokens, tree.source, comments);
	}

	/** Compatibility path for callers that only have formatter tokens. */
	static function attachTokenStream(tokens:Array<FormatToken>):CommentAttachments {
		return attachWithNewlineSource(tokens, null, null);
	}

	static function attachWithNewlineSource(tokens:Array<FormatToken>, source:Null<SourceFile>, cstComments:Null<Map<Int, Bool>>):CommentAttachments {
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
					if (cstComments != null && !cstComments.exists(token.start))
						continue;
					var previous = previousSyntax,
						nextToken = nextSyntax[index],
						lineBreakBefore = hasNewline(tokens, source, previous, index),
						lineBreakAfter = hasNewline(tokens, source, index, nextToken);
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

	static function isComment(kind:SyntaxTriviaKind):Bool
		return switch kind {
			case SyntaxTriviaKind.LineComment, SyntaxTriviaKind.BlockComment, SyntaxTriviaKind.DocComment: true;
			default: false;
		};

	static function hasNewline(tokens:Array<FormatToken>, source:Null<SourceFile>, start:Null<Int>, end:Null<Int>):Bool {
		if (start == null || end == null)
			return false;
		if (source != null)
			return source.slice(tokens[start].end, tokens[end].start).indexOf("\n") >= 0
				|| source.slice(tokens[start].end, tokens[end].start).indexOf("\r") >= 0;
		for (index in start + 1...end + 1)
			if (FormatTokenTools.hasNewline(tokens[index]))
				return true;
		return false;
	}
}
