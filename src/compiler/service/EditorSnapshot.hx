package compiler.service;

import compiler.Source.SourceFile;
import compiler.modules.ModuleState;
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

/** Central selection policy for source-aware editor queries. */
class EditorSnapshotTools {
	public static function select(state:ModuleState):Null<EditorSnapshot> {
		if (state.ast != null)
			return {
				source: state.source,
				tokens: state.tokens,
				ast: state.ast,
				semanticModel: state.semanticModel,
				revision: state.revision,
				stale: false,
				recovered: false,
				confidence: EditorSnapshotConfidence.Exact
			};

		if (state.recoveredAst != null)
			return {
				source: state.source,
				tokens: state.recoveredTokens,
				ast: state.recoveredAst,
				semanticModel: state.recoveredSemanticModel,
				revision: state.revision,
				stale: false,
				recovered: true,
				confidence: EditorSnapshotConfidence.RecoveredPartial
			};

		if (state.lastGoodAst != null && state.lastGoodSource != null && state.lastGoodSemanticModel != null)
			return {
				source: state.lastGoodSource,
				tokens: state.lastGoodTokens,
				ast: state.lastGoodAst,
				semanticModel: state.lastGoodSemanticModel,
				revision: state.lastGoodRevision,
				stale: true,
				recovered: false,
				confidence: EditorSnapshotConfidence.LastGood
			};

		return null;
	}
}
