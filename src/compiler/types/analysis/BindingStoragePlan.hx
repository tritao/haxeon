package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.CellStorageKind;

private typedef StorageCandidate = {
	final cellPrefix:String;
	final kind:CellStorageKind;
}

/** Resolves conservative source-name storage requests to lexical binding IDs. */
class BindingStoragePlan {
	final candidates:Map<String, StorageCandidate> = [];

	public final cells:Map<String, String> = [];
	public final types:Map<String, CompilerType> = [];
	public final kinds:Map<String, CellStorageKind> = [];

	public function new() {}

	public function request(sourceName:String, cellPrefix:String, kind:CellStorageKind):Void {
		var current = candidates.get(sourceName);
		if (current == null || current.kind == ExceptionEdge && kind == MutableCapture)
			candidates.set(sourceName, {cellPrefix: cellPrefix, kind: kind});
	}

	public function hasCandidate(sourceName:String):Bool
		return candidates.exists(sourceName);

	public function candidateKind(sourceName:String):Null<CellStorageKind> {
		var candidate = candidates.get(sourceName);
		return candidate == null ? null : candidate.kind;
	}

	public function candidateNames():Array<String>
		return [for (name in candidates.keys()) name];

	public function bind(sourceName:String, bindingId:String, type:CompilerType):Null<String> {
		var candidate = candidates.get(sourceName);
		if (candidate == null)
			return null;
		if (!cells.exists(bindingId)) {
			cells.set(bindingId, candidate.cellPrefix + ":" + bindingId);
			types.set(bindingId, type);
			kinds.set(bindingId, candidate.kind);
		}
		return cells.get(bindingId);
	}

	public function cell(bindingId:String):Null<String>
		return cells.get(bindingId);
}
