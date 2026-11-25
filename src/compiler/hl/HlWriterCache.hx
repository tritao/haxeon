package compiler.hl;

import compiler.core.SourceAnchor.SourceAnchors;
import compiler.hl.HlFunction.HlDebugLocation;
import haxe.ds.ObjectMap;
import haxe.io.Bytes;
import haxeon.io.SegmentedBytes;

/**
 * Encoded function bodies that remain valid while the debug-file table is stable and the anchors their lines count from are where
 * they were (`HlDebugLocation`).
 */
class HlWriterCache {
	var debugFiles:Array<String> = [];
	var functions:ObjectMap<HlFunction, EncodedFunction> = new ObjectMap();
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

	/** By debug section kind, the last payload compressed and what it was stored as (`HlWriter.storedSection`). */
	var compressed:Map<Int, CompressedSection> = [];

	public function new() {}

	/** What the section of `kind` was stored as when its payload was `decoded`, compressed at `level`; null if it was not. */
	public function compressedSection(kind:Int, level:Int, decoded:Bytes):Null<SegmentedBytes> {
		var known = compressed.get(kind);
		return known != null && known.level == level && known.decoded.compare(decoded) == 0 ? known.stored : null;
	}

	public function setCompressedSection(kind:Int, level:Int, decoded:Bytes, stored:SegmentedBytes):Void
		compressed.set(kind, new CompressedSection(level, decoded, stored));

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
	public function spanGroup(locations:Array<HlDebugLocation>, stableId:Int, fileIndices:Map<String, Int>,
			sources:SourceAnchors):Null<Bytes> {
		var entry = spanGroups.get(locations);
		if (entry == null || entry.stableId != stableId)
			return null;
		for (index in 0...entry.paths.length)
			if (fileIndices.get(entry.paths[index]) != entry.indices[index])
				return null;
		return entry.places.hold(sources) ? entry.bytes : null;
	}

	public function setSpanGroup(locations:Array<HlDebugLocation>, stableId:Int, bytes:Bytes,
			fileIndices:Map<String, Int>, sources:SourceAnchors):Void {
		var paths:Array<String> = [], indices:Array<Int> = [], places = AnchorPlaces.of(locations, sources, true);
		for (anchor in places.anchors()) {
			var path = sources.path(anchor);
			if (paths.indexOf(path) < 0) {
				paths.push(path);
				var index = fileIndices.get(path);
				indices.push(index == null ? 0 : index);
			}
		}
		spanGroups.set(locations, new SpanGroupBytes(stableId, bytes, paths, indices, places));
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

	/** The encoding of `fn`, if its lines are still where `sources` puts them. */
	public function get(fn:HlFunction, sources:SourceAnchors):Null<Bytes> {
		var entry = functions.get(fn);
		if (entry == null)
			return null;
		var places = entry.places;
		return places == null || places.hold(sources) ? entry.bytes : null;
	}

	/** Keeps the encoding of `fn`, with the lines its anchors had in `sources` when it was written with debug lines. */
	public function set(fn:HlFunction, bytes:Bytes, sources:Null<SourceAnchors>):Void
		functions.set(fn,
			new EncodedFunction(bytes, sources == null ? null : AnchorPlaces.of(fn.debugLocations, sources,
			false)));

	public function isValidated(fn:HlFunction):Bool
		return validatedFunctions.exists(fn);

	public function markValidated(fn:HlFunction):Void
		validatedFunctions.set(fn, true);

	/**
	 * Keeps encoded bodies and validation marks only for the functions of the module just written, so a
	 * long-lived session releases the functions an edit replaced.
	 */
	public function retainFunctions(active:Array<HlFunction>):Void {
		var keptFunctions = new ObjectMap<HlFunction, EncodedFunction>(),
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

/** One function's encoded span group with the file indices and anchor places it was encoded under. */
private class SpanGroupBytes {
	public final stableId:Int;
	public final bytes:Bytes;
	public final paths:Array<String>;
	public final indices:Array<Int>;
	public final places:AnchorPlaces;

	public function new(stableId:Int, bytes:Bytes, paths:Array<String>, indices:Array<Int>, places:AnchorPlaces) {
		this.stableId = stableId;
		this.bytes = bytes;
		this.paths = paths;
		this.indices = indices;
		this.places = places;
	}
}

/** One function's encoding, with where its anchors were when its debug lines were written (null when it has none). */
private class EncodedFunction {
	public final bytes:Bytes;
	public final places:Null<AnchorPlaces>;

	public function new(bytes:Bytes, places:Null<AnchorPlaces>) {
		this.bytes = bytes;
		this.places = places;
	}
}

/**
 * The distinct anchors of some debug locations, each with its line (and with `full`, its offset and file hash) in a build's
 * sources, in one array of rows: a writer cache holds one for every function.
 */
private class AnchorPlaces {
	final rows:Array<Int> = [];
	final width:Int;

	function new(full:Bool)
		width = full ? 4 : 2;

	public static function of(locations:Array<HlDebugLocation>, sources:SourceAnchors, full:Bool):AnchorPlaces {
		var result = new AnchorPlaces(full), rows = result.rows, previous = -1;
		for (location in locations) {
			var anchor = location.anchor;
			if (anchor == previous || result.has(anchor))
				continue;
			previous = anchor;
			rows.push(anchor);
			rows.push(sources.line(anchor));
			if (full) {
				rows.push(sources.offset(anchor));
				rows.push(sources.hash(anchor));
			}
		}
		return result;
	}

	function has(anchor:Int):Bool {
		var index = 0;
		while (index < rows.length) {
			if (rows[index] == anchor)
				return true;
			index += width;
		}
		return false;
	}

	public function anchors():Array<Int>
		return [for (index in 0...Std.int(rows.length / width)) rows[index * width]];

	/** Whether every anchor is where `sources` puts it now. */
	public function hold(sources:SourceAnchors):Bool {
		var index = 0;
		while (index < rows.length) {
			var anchor = rows[index];
			if (sources.line(anchor) != rows[index + 1]
				|| width == 4 && (sources.offset(anchor) != rows[index + 2] || sources.hash(anchor) != rows[index + 3]))
				return false;
			index += width;
		}
		return true;
	}
}

/** A debug section's payload and the compressed form the writer stored it as. */
private class CompressedSection {
	public final level:Int;
	public final decoded:Bytes;
	public final stored:SegmentedBytes;

	public function new(level:Int, decoded:Bytes, stored:SegmentedBytes) {
		this.level = level;
		this.decoded = decoded;
		this.stored = stored;
	}
}
