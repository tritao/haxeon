package compiler.hl;

import haxe.ds.ObjectMap;
import haxe.io.Bytes;

/** Encoded function bodies that remain valid while the debug-file table is stable. */
class HlWriterCache {
	var debugFiles:Array<String> = [];
	var functions:ObjectMap<HlFunction, Bytes> = new ObjectMap();
	var validatedFunctions:ObjectMap<HlFunction, Bool> = new ObjectMap();
	var validatedSnapshots:ObjectMap<Bytes, Int> = new ObjectMap();

	public function new() {}

	public function prepare(files:Array<String>):Void {
		if (sameStrings(debugFiles, files))
			return;
		debugFiles = files.copy();
		functions = new ObjectMap();
		validatedFunctions = new ObjectMap();
	}

	public function get(fn:HlFunction):Null<Bytes>
		return functions.get(fn);

	public function set(fn:HlFunction, bytes:Bytes):Void
		functions.set(fn, bytes);

	public function isValidated(fn:HlFunction):Bool
		return validatedFunctions.exists(fn);

	public function markValidated(fn:HlFunction):Void
		validatedFunctions.set(fn, true);

	public function isSnapshotValidated(content:Bytes, sourceHash:Int):Bool
		return validatedSnapshots.get(content) == sourceHash;

	public function markSnapshotValidated(content:Bytes, sourceHash:Int):Void
		validatedSnapshots.set(content, sourceHash);

	static function sameStrings(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}
}
