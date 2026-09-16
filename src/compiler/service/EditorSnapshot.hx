package compiler.service;

import compiler.Source.SourceFile;
import compiler.modules.ModuleState;
import compiler.modules.AnalysisSnapshot;
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
		if (state.currentExact != null && state.currentExact.isCurrent(state.revision))
			return toEditor(state.currentExact, EditorSnapshotConfidence.Exact);

		var recovered = currentRecovered(state);
		if (recovered != null)
			return recovered;

		if (state.lastGood != null)
			return toEditor(state.lastGood, EditorSnapshotConfidence.LastGood);

		return null;
	}

	/** Return the current-source recovery view without applying fallback policy. */
	public static function currentRecovered(state:ModuleState):Null<EditorSnapshot> {
		var snapshot = state.currentRecovered;
		return snapshot == null || !snapshot.isCurrent(state.revision) ? null : toEditor(snapshot, EditorSnapshotConfidence.RecoveredPartial);
	}

	static function toEditor(snapshot:AnalysisSnapshot, confidence:EditorSnapshotConfidence):EditorSnapshot
		return {
			source: snapshot.source,
			tokens: snapshot.tokens,
			ast: snapshot.ast,
			semanticModel: snapshot.semanticModel,
			revision: snapshot.revision,
			stale: snapshot.stale,
			recovered: snapshot.recovered,
			confidence: confidence
		};
}
