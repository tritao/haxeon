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
	public static function attach(tokens:Array<FormatToken>, tree:SyntaxTree):CommentAttachments
		return attachCst(tokens, tree);

	/** Uses CST trivia and source spans as the authoritative comment stream. */
	static function attachCst(tokens:Array<FormatToken>, tree:SyntaxTree):CommentAttachments {
		var comments:Map<Int, Bool> = [];
		for (trivia in tree.trivia)
			if (isComment(trivia.kind))
				comments.set(trivia.span.start, true);
		var tokenAtStart:Map<Int, Int> = [], tokenAtEnd:Map<Int, Int> = [];
		for (index in 0...tokens.length) {
			tokenAtStart.set(tokens[index].start, index);
			tokenAtEnd.set(tokens[index].end, index);
		}
		return attachWithCst(tokens, tree, comments, tokenAtStart, tokenAtEnd);
	}

	static function attachWithCst(tokens:Array<FormatToken>, tree:SyntaxTree, comments:Map<Int, Bool>, tokenAtStart:Map<Int, Int>,
			tokenAtEnd:Map<Int, Int>):CommentAttachments {
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
					if (!comments.exists(token.start))
						continue;
					var previous = previousSyntax,
						nextToken = nextSyntax[index],
						lineBreakBefore = hasNewline(tokens, tree.source, previous, index),
						lineBreakAfter = hasNewline(tokens, tree.source, index, nextToken);
					if (isDangling(tree, token, previous, nextToken, tokenAtStart, tokenAtEnd))
						result.set(index, CommentAttachmentKind.Standalone);
					else if (token.kind == FormatTokenKind.DocComment && nextToken != null)
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

	/** A comment between a CST node's real delimiters is dangling, not leading. */
	static function isDangling(tree:SyntaxTree, token:FormatToken, previous:Null<Int>, next:Null<Int>, tokenAtStart:Map<Int, Int>,
			tokenAtEnd:Map<Int, Int>):Bool {
		if (previous == null || next == null)
			return false;
		for (node in tree.grammarNodes()) {
			if (node.span.start > token.start || node.span.end < token.end)
				continue;
			var open = tokenAtStart.get(node.span.start), close = tokenAtEnd.get(node.span.end);
			if (open == previous && close == next)
				return true;
		}
		return false;
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
