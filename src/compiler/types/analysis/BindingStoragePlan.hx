package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.CellStorageKind;

private typedef StorageCandidate = {
	final cellPrefix:String;
	final kind:CellStorageKind;
}

/** Resolves declaration-site storage requests to typed lexical binding IDs. */
class BindingStoragePlan {
	final candidates:Map<String, StorageCandidate> = [];

	public final cells:Map<String, String> = [];
	public final types:Map<String, CompilerType> = [];
	public final kinds:Map<String, CellStorageKind> = [];

	/** Declarations a closure can write, distinct from cells needed only for parent writes or exception edges. */
	public final closureWrites:Map<String, Bool> = [];

	/** Cells named so far under each prefix. */
	final prefixCounts:Map<String, Int> = [];

	public function new() {}

	public function request(declarationKey:String, cellPrefix:String, kind:CellStorageKind):Void {
		var current = candidates.get(declarationKey);
		if (current == null || current.kind == ExceptionEdge && kind == MutableCapture)
			candidates.set(declarationKey, {cellPrefix: cellPrefix, kind: kind});
	}

	public function hasCandidate(declarationKey:String):Bool
		return candidates.exists(declarationKey);

	public function candidateKind(declarationKey:String):Null<CellStorageKind> {
		var candidate = candidates.get(declarationKey);
		return candidate == null ? null : candidate.kind;
	}

	public function candidateSourceNames():Array<String> {
		var result:Map<String, Bool> = [];
		for (declarationKey in candidates.keys()) {
			var separator = declarationKey.lastIndexOf("@");
			result.set(separator < 0 ? declarationKey : declarationKey.substring(0, separator), true);
		}
		return [for (name in result.keys()) name];
	}

	public function bind(declarationKey:String, bindingId:String, type:CompilerType):Null<String> {
		var candidate = candidates.get(declarationKey);
		if (candidate == null)
			return null;
		if (!cells.exists(bindingId)) {
			cells.set(bindingId, cellName(candidate.cellPrefix));
			types.set(bindingId, type);
			kinds.set(bindingId, candidate.kind);
		}
		return cells.get(bindingId);
	}

	public function requestBinding(bindingId:String, cellPrefix:String, kind:CellStorageKind, type:CompilerType):String {
		if (!cells.exists(bindingId)) {
			cells.set(bindingId, cellName(cellPrefix));
			types.set(bindingId, type);
			kinds.set(bindingId, kind);
		} else if (kinds.get(bindingId) == ExceptionEdge && kind == MutableCapture)
			kinds.set(bindingId, kind);
		return cells.get(bindingId);
	}

	/**
	 * A cell class is named by its prefix (`$cell:<function>:<local>`) and the order the function declares cells under it, not by
	 * the binding ID, which counts every local declared before it: a new local above a captured one would rename its cell, change
	 * the layout of every closure environment holding it, and turn a patchable edit into a reload.
	 */
	function cellName(prefix:String):String {
		var ordinal:Int = prefixCounts.exists(prefix) ? prefixCounts.get(prefix) : 0;
		prefixCounts.set(prefix, ordinal + 1);
		return prefix + "#" + ordinal;
	}

	public function cell(bindingId:String):Null<String>
		return cells.get(bindingId);
}
