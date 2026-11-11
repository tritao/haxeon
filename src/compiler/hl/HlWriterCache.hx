package compiler.hl;

import compiler.hl.HlFunction.HlDebugLocation;
import haxe.ds.ObjectMap;
import haxe.io.Bytes;

/** Encoded function bodies that remain valid while the debug-file table is stable. */
class HlWriterCache {
	var debugFiles:Array<String> = [];
	var functions:ObjectMap<HlFunction, Bytes> = new ObjectMap();
	var functionPaths:ObjectMap<HlFunction, Array<String>> = new ObjectMap();
	var validatedFunctions:ObjectMap<HlFunction, Bool> = new ObjectMap();
	var validatedSnapshots:ObjectMap<Bytes, Int> = new ObjectMap();
	var spanGroups:ObjectMap<Array<HlDebugLocation>, SpanGroupBytes> = new ObjectMap();
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
		// Encoded bodies and the prefix name debug files by index, so they go. Validation does not depend on that list, and
		// `HlValidator` marks functions before the writer prepares the cache: clearing the marks here made the first build
		// after a different file list validate every function again.
		debugFiles = files.copy();
		functions = new ObjectMap();
		prefix = null;
	}

	/**
	 * The encoded opcode source-span group of a function, if `locations` is the array it was encoded from, for the same stable id, and every
	 * file it names has the index it had then (the file table is built from all groups, so it can shift).
	 */
	public function spanGroup(locations:Array<HlDebugLocation>, stableId:Int, fileIndices:Map<String, Int>):Null<Bytes> {
		var entry = spanGroups.get(locations);
		if (entry == null || entry.stableId != stableId)
			return null;
		for (index in 0...entry.paths.length)
			if (fileIndices.get(entry.paths[index]) != entry.indices[index])
				return null;
		return entry.bytes;
	}

	public function setSpanGroup(locations:Array<HlDebugLocation>, stableId:Int, bytes:Bytes, fileIndices:Map<String, Int>):Void {
		var paths:Array<String> = [], indices:Array<Int> = [], previous = "";
		for (location in locations)
			if (location.path != previous) {
				previous = location.path;
				if (paths.indexOf(previous) < 0) {
					paths.push(previous);
					var index = fileIndices.get(previous);
					indices.push(index == null ? 0 : index);
				}
			}
		spanGroups.set(locations, new SpanGroupBytes(stableId, bytes, paths, indices));
	}

	/** Keeps the span groups of the functions just written, so a long-lived session releases the ones an edit replaced. */
	public function retainSpanGroups(active:Null<Array<Array<HlDebugLocation>>>):Void {
		if (active == null)
			return;
		var kept = new ObjectMap<Array<HlDebugLocation>, SpanGroupBytes>();
		for (locations in active) {
			var entry = spanGroups.get(locations);
			if (entry != null)
				kept.set(locations, entry);
		}
		spanGroups = kept;
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
			var sourceHash = validatedSnapshots.get(content);
			if (sourceHash != null)
				kept.set(content, sourceHash);
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

/** One function's encoded span group with the file indices it was encoded under. */
private class SpanGroupBytes {
	public final stableId:Int;
	public final bytes:Bytes;
	public final paths:Array<String>;
	public final indices:Array<Int>;

	public function new(stableId:Int, bytes:Bytes, paths:Array<String>, indices:Array<Int>) {
		this.stableId = stableId;
		this.bytes = bytes;
		this.paths = paths;
		this.indices = indices;
	}
}
