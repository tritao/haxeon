package compiler.hl;

import haxe.ds.ObjectMap;
import haxe.io.Bytes;

/** Encoded function bodies that remain valid while the debug-file table is stable. */
class HlWriterCache {
	var debugFiles:Array<String> = [];
	var functions:ObjectMap<HlFunction, Bytes> = new ObjectMap();
	var functionPaths:ObjectMap<HlFunction, Array<String>> = new ObjectMap();
	var validatedFunctions:ObjectMap<HlFunction, Bool> = new ObjectMap();
	var validatedSnapshots:ObjectMap<Bytes, Int> = new ObjectMap();
	var prefix:Null<Bytes>;
	var prefixInts:Dynamic;
	var prefixFloats:Dynamic;
	var prefixStrings:Dynamic;
	var prefixTypes:Dynamic;
	var prefixGlobals:Dynamic;
	var prefixNativeKey = "";
	var prefixFunctions = -1;
	var prefixConstants = -1;
	var prefixEntryPoint = -1;

	public function new() {}

	public function prepare(files:Array<String>):Void {
		if (sameStrings(debugFiles, files))
			return;
		debugFiles = files.copy();
		functions = new ObjectMap();
		validatedFunctions = new ObjectMap();
		prefix = null;
	}

	public function get(fn:HlFunction):Null<Bytes>
		return functions.get(fn);

	public function set(fn:HlFunction, bytes:Bytes):Void
		functions.set(fn, bytes);

	public function paths(fn:HlFunction):Null<Array<String>>
		return functionPaths.get(fn);

	public function retainPaths(active:ObjectMap<HlFunction, Array<String>>):Void
		functionPaths = active;

	public function isValidated(fn:HlFunction):Bool
		return validatedFunctions.exists(fn);

	public function markValidated(fn:HlFunction):Void
		validatedFunctions.set(fn, true);

	/**
	 * Keeps encoded bodies and validation marks only for the functions of the module just written, so a
	 * long-lived session releases the functions an edit replaced.
	 */
	public function retainFunctions(active:Array<HlFunction>):Void {
		var keptFunctions = new ObjectMap<HlFunction, Bytes>(),
			keptValidated = new ObjectMap<HlFunction, Bool>();
		for (fn in active) {
			var encoded = functions.get(fn);
			if (encoded != null)
				keptFunctions.set(fn, encoded);
			if (validatedFunctions.exists(fn))
				keptValidated.set(fn, true);
		}
		functions = keptFunctions;
		validatedFunctions = keptValidated;
	}

	/** Keeps snapshot validation marks only for the snapshots of the module just validated. */
	public function retainSnapshots(active:Array<Bytes>):Void {
		var kept = new ObjectMap<Bytes, Int>();
		for (content in active) {
			var mark = validatedSnapshots.get(content);
			if (mark != null)
				kept.set(content, mark);
		}
		validatedSnapshots = kept;
	}

	public function isSnapshotValidated(content:Bytes, sourceHash:Int):Bool
		return validatedSnapshots.get(content) == sourceHash;

	public function markSnapshotValidated(content:Bytes, sourceHash:Int):Void
		validatedSnapshots.set(content, sourceHash);

	public function getPrefix(code:HlCode):Null<Bytes> {
		var nativeKey = [
			for (native in code.natives)
				'${native.library}:${native.name}:${native.type}:${native.functionIndex}'
		].join("|");
		return prefixInts == code.ints
			&& prefixFloats == code.floats
			&& prefixStrings == code.strings
			&& prefixTypes == code.types
			&& prefixGlobals == code.globals
			&& prefixNativeKey == nativeKey
			&& prefixFunctions == code.functions.length
			&& prefixConstants == code.constants.length
			&& prefixEntryPoint == code.entryPoint ? prefix : null;
	}

	public function setPrefix(code:HlCode, bytes:Bytes):Void {
		prefix = bytes;
		prefixInts = code.ints;
		prefixFloats = code.floats;
		prefixStrings = code.strings;
		prefixTypes = code.types;
		prefixGlobals = code.globals;
		prefixNativeKey = [
			for (native in code.natives)
				'${native.library}:${native.name}:${native.type}:${native.functionIndex}'
		].join("|");
		prefixFunctions = code.functions.length;
		prefixConstants = code.constants.length;
		prefixEntryPoint = code.entryPoint;
	}

	static function sameStrings(left:Array<String>, right:Array<String>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index] != right[index])
				return false;
		return true;
	}
}
