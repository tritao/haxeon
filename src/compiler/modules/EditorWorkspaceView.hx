package compiler.modules;

import compiler.semantic.SemanticModel;

/**
	Compiler-owned selection of the source-aware editor snapshots.

	This view intentionally excludes the mutable in-flight compiler candidate
	used while strict analysis is being assembled. Editor queries may observe
	exact, current recovered, or last-good publications only.
*/
class EditorWorkspaceView {
	public static function currentExact(state:ModuleState):Null<AnalysisSnapshot>
		return state.currentExact == null || !state.currentExact.isCurrent(state.revision) ? null : state.currentExact;

	public static function currentRecovered(state:ModuleState):Null<AnalysisSnapshot>
		return state.currentRecovered == null || !state.currentRecovered.isCurrent(state.revision) ? null : state.currentRecovered;

	public static function lastGood(state:ModuleState):Null<AnalysisSnapshot>
		return state.lastGood;

	public static function select(state:ModuleState):Null<AnalysisSnapshot> {
		var exact = currentExact(state);
		if (exact != null)
			return exact;
		var recovered = currentRecovered(state);
		if (recovered != null)
			return recovered;
		return lastGood(state);
	}

	public static function semanticModel(state:ModuleState):Null<SemanticModel> {
		var snapshot = select(state);
		return snapshot == null ? null : snapshot.semanticModel;
	}
}
