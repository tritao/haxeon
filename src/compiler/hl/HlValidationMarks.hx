package compiler.hl;

import haxe.ds.ObjectMap;
import haxe.io.Bytes;

/**
 * The functions and source snapshots `HlValidator` has checked, by object: a build that keeps them (`HlSectionCache`) does not
 * check them again while they are the same objects.
 */
class HlValidationMarks {
	var functions:ObjectMap<HlFunction, Bool> = new ObjectMap();
	var snapshots:ObjectMap<Bytes, Int> = new ObjectMap();

	public function new() {}

	public function isValidated(fn:HlFunction):Bool
		return functions.exists(fn);

	public function markValidated(fn:HlFunction):Void
		functions.set(fn, true);

	/** Keeps the marks of the functions of the module just written only, so a long-lived session releases the ones an edit replaced. */
	public function retainFunctions(active:Array<HlFunction>):Void {
		var kept = new ObjectMap<HlFunction, Bool>();
		for (fn in active)
			if (functions.exists(fn))
				kept.set(fn, true);
		functions = kept;
	}

	/** Keeps the marks of the snapshots of the module just validated only. */
	public function retainSnapshots(active:Array<Bytes>):Void {
		var kept = new ObjectMap<Bytes, Int>();
		for (content in active) {
			var sourceHash = snapshots.get(content);
			if (sourceHash != null)
				kept.set(content, sourceHash);
		}
		snapshots = kept;
	}

	public function isSnapshotValidated(content:Bytes, sourceHash:Int):Bool
		return snapshots.get(content) == sourceHash;

	public function markSnapshotValidated(content:Bytes, sourceHash:Int):Void
		snapshots.set(content, sourceHash);
}
