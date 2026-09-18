package compiler.syntax;

import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxNode;
import compiler.syntax.SyntaxTree.SyntaxNodePayload;
import compiler.syntax.SyntaxTree.SyntaxTree;

class SyntaxTreeDraft {
	public final kind:SyntaxKind;
	public final start:Int;
	public var end:Int;
	public final children:Array<SyntaxTreeDraft> = [];
	public final payload:Null<SyntaxNodePayload>;

	public function new(kind:SyntaxKind, start:Int, end:Int, ?payload:SyntaxNodePayload) {
		this.kind = kind;
		this.start = start;
		this.end = end;
		this.payload = payload;
	}
}

/** Collects grammar events without owning or rebuilding parser decisions. */
class SyntaxTreeBuilder {
	final source:SourceFile;
	final drafts:Array<SyntaxTreeDraft> = [];

	public function new(source:SourceFile)
		this.source = source;

	public function node(kind:SyntaxKind, span:SourceSpan, ?payload:SyntaxNodePayload):Void
		drafts.push(new SyntaxTreeDraft(kind, span.start, span.end, payload));

	public function missing(span:SourceSpan):Void
		drafts.push(new SyntaxTreeDraft(SyntaxKind.Missing, span.start, span.end));

	public function error(span:SourceSpan):Void
		drafts.push(new SyntaxTreeDraft(SyntaxKind.Error, span.start, span.end));

	public function startNode(kind:SyntaxKind, start:Int):SyntaxTreeDraft {
		var draft = new SyntaxTreeDraft(kind, start, start);
		drafts.push(draft);
		return draft;
	}

	public function finishNode(draft:SyntaxTreeDraft, end:Int):Void
		draft.end = end;

	/** Nests completed source ranges so grammar parents contain their children. */
	public function finish():Array<SyntaxNode> {
		var ordered:Array<SyntaxTreeDraft> = drafts.copy(), orderedLength = 0;
		for (draft in drafts)
			if (draft.end >= draft.start)
				ordered[orderedLength++] = draft;
		ordered.resize(orderedLength);
		ordered.sort(function(left, right) {
			if (left.start != right.start)
				return left.start - right.start;
			return right.end - left.end;
		});
		var roots:Array<SyntaxTreeDraft> = [], stack:Array<SyntaxTreeDraft> = [];
		for (draft in ordered) {
			while (stack.length > 0 && draft.start >= stack[stack.length - 1].end)
				stack.pop();
			if (stack.length == 0)
				roots.push(draft);
			else if (draft.end <= stack[stack.length - 1].end)
				stack[stack.length - 1].children.push(draft);
			else {
				// Parser events should be nested, but keep an overlapping event
				// visible rather than silently attaching it to the wrong parent.
				while (stack.length > 0 && draft.end > stack[stack.length - 1].end)
					stack.pop();
				if (stack.length == 0)
					roots.push(draft);
				else
					stack[stack.length - 1].children.push(draft);
			}
			stack.push(draft);
		}
		return [for (root in roots) materialize(root)];
	}

	function materialize(draft:SyntaxTreeDraft):SyntaxNode {
		var children:Array<SyntaxNode> = [];
		children.resize(draft.children.length);
		for (index in 0...draft.children.length)
			children[index] = materialize(draft.children[index]);
		return SyntaxNode.fromOwned(draft.kind, source.span(draft.start, draft.end), [],
			children, draft.payload);
	}
}
