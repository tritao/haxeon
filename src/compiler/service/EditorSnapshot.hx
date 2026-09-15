package compiler.service;

import compiler.Source.SourceFile;
import compiler.semantic.SemanticModel;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Token;

/** Confidence attached to an editor snapshot or a query derived from it. */
enum EditorSnapshotConfidence {
	Exact;
	RecoveredStable;
	RecoveredPartial;
	LastGood;
}

/** Compiler-owned view selected for a source-aware editor query. */
typedef EditorSnapshot = {
	final source:SourceFile;
	final tokens:Array<Token>;
	final ast:AstProgram;
	final semanticModel:Null<SemanticModel>;
	final revision:Int;
	final stale:Bool;
	final recovered:Bool;
	final confidence:EditorSnapshotConfidence;
}
