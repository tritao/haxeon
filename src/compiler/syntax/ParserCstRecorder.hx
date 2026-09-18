package compiler.syntax;

import compiler.Source.SourceFile;
import compiler.Source.SourceSpan;
import compiler.syntax.SyntaxScanner.LosslessToken;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxNodePayload;
import compiler.syntax.SyntaxTree.SyntaxToken;
import compiler.syntax.SyntaxTree.SyntaxTree;
import compiler.syntax.Token.TokenKind;

/**
	Owns the optional CST side channel used by Parser.

	Keeping this state together makes AST-only parsing genuinely unaware of CST
	publication while preserving the parser's single grammar and recovery path.
*/
class ParserCstRecorder {
	public var tree(default, null):SyntaxTree;
	final builder:SyntaxTreeBuilder;
	final missingTokens:Array<SyntaxToken> = [];

	public function new(source:SourceFile, ?losslessTokens:Array<LosslessToken>) {
		builder = new SyntaxTreeBuilder(source);
		tree = losslessTokens == null ? SyntaxTree.fromSource(source) : SyntaxTree.fromLossless(source, losslessTokens);
	}

	public inline function node(kind:SyntaxKind, span:SourceSpan, ?payload:SyntaxNodePayload):Void
		builder.node(kind, span, payload);

	public inline function missing(span:SourceSpan):Void
		builder.missing(span);

	public inline function error(span:SourceSpan):Void
		builder.error(span);

	public function addMissingToken(kind:TokenKind, span:SourceSpan, ?replacement:String):Void {
		missingTokens.push(SyntaxToken.missing(kind, span.file, span.start, replacement));
	}

	public function finish():Void
		tree = tree.withGrammarRootsAndSynthetic(builder.finish(), missingTokens);
}
