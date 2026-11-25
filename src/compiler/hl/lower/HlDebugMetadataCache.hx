package compiler.hl.lower;

import compiler.core.SourceAnchor.SourceAnchors;
import compiler.hl.HlCode.HlFunctionIdentity;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrFunction;
import haxe.ds.ObjectMap;

/**
 * Function identities memoized by persistent function identity: each function's place in its sources, counted from its anchors
 * (`HlFunctionPlace`), and the identity last made from it. Entries live for one generation: a lowering keeps only the fragments it
 * used, so functions replaced by an edit are released instead of accumulating in a long-lived compiler session.
 */
@:nullSafety(Strict)
class HlDebugMetadataCache {
	var entries:ObjectMap<IrFunction, HlIdentityEntry> = new ObjectMap();
	var nextEntries:ObjectMap<IrFunction, HlIdentityEntry> = new ObjectMap();

	public function new() {}

	/**
	 * The identity of `fn` at `functionIndex` with `stableId`, its place found in `sources`: the one made last time while it reads the
	 * same, so an unchanged function in an unchanged place costs no allocation.
	 */
	public function identity(fn:IrFunction, body:IrBody, functionIndex:Int, stableId:Int,
			sources:SourceAnchors):HlFunctionIdentity {
		var entry = nextEntries.get(fn);
		if (entry == null) {
			entry = entries.get(fn);
			if (entry == null)
				entry = new HlIdentityEntry(HlFunctionPlace.of(body));
			nextEntries.set(fn, entry);
		}
		var place = entry.place, known = entry.identity;
		if (known == null || known.functionIndex != functionIndex || known.stableId != stableId
			|| !place.reads(known, sources)) {
			known = place.identity(fn.name, functionIndex, stableId, sources);
			entry.identity = known;
		}
		return known;
	}

	var lastIdentities:Array<HlFunctionIdentity> = [];
	var lastPayload:Null<haxe.io.Bytes> = null;

	/** The function identities section's payload (`HlWriter.encodeFunctionIdentities`): the last one while the identities read the same. */
	public function identitiesPayload(identities:Array<HlFunctionIdentity>):haxe.io.Bytes {
		var payload = lastPayload;
		if (payload != null && sameIdentities(lastIdentities, identities))
			return payload;
		payload = compiler.hl.HlWriter.encodeFunctionIdentities(identities);
		lastIdentities = identities;
		lastPayload = payload;
		return payload;
	}

	static function sameIdentities(left:Array<HlFunctionIdentity>, right:Array<HlFunctionIdentity>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length) {
			var a = left[index], b = right[index];
			if (a != b
				&& (a.stableId != b.stableId || a.functionIndex != b.functionIndex || a.qualifiedName != b.qualifiedName
				|| a.displayName != b.displayName || a.sourcePath != b.sourcePath || a.start != b.start
				|| a.end != b.end
				|| a.line != b.line || a.flags != b.flags))
				return false;
		}
		return true;
	}

	/** Drops every fragment the finished lowering did not use. */
	public function endGeneration():Void {
		entries = nextEntries;
		nextEntries = new ObjectMap();
	}
}

private class HlIdentityEntry {
	public final place:HlFunctionPlace;
	public var identity:Null<HlFunctionIdentity> = null;

	public function new(place:HlFunctionPlace)
		this.place = place;
}

/**
 * Where a function's code is, per anchor its instructions name (terminators aside): the least start, the greatest end and the
 * least line, counted from the anchor, and the anchor of its first location. The identity takes the least and greatest of those
 * over all anchors once each is placed, which is what it takes over the placed locations.
 */
@:nullSafety(Strict)
class HlFunctionPlace {
	final first:Int;
	final anchors:Array<Int> = [];
	final starts:Array<Int> = [];
	final ends:Array<Int> = [];
	final lines:Array<Int> = [];

	function new(first:Int)
		this.first = first;

	public static function of(body:IrBody):HlFunctionPlace {
		var place:Null<HlFunctionPlace> = null;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block), terminator = body.terminatorRow(block);
			while (row >= 0 && row != terminator) {
				var location = body.provenance(row).location;
				row = body.nextRow(row);
				if (location == null)
					continue;
				if (place == null)
					place = new HlFunctionPlace(location.anchor);
				place.add(location.anchor, location.start, location.end, location.line);
			}
		}
		return place ?? new HlFunctionPlace(-1);
	}

	function add(anchor:Int, start:Int, end:Int, line:Int):Void {
		var index = anchors.indexOf(anchor);
		if (index < 0) {
			anchors.push(anchor);
			starts.push(start);
			ends.push(end);
			lines.push(line);
			return;
		}
		if (start < starts[index])
			starts[index] = start;
		if (end > ends[index])
			ends[index] = end;
		if (line < lines[index])
			lines[index] = line;
	}

	public function identity(name:String, functionIndex:Int, stableId:Int, sources:SourceAnchors):HlFunctionIdentity {
		var parts = name.split(".");
		return {
			stableId: stableId,
			functionIndex: functionIndex,
			qualifiedName: name,
			displayName: parts[parts.length - 1],
			sourcePath: path(sources),
			start: start(sources),
			end: end(sources),
			line: line(sources),
			flags: StringTools.startsWith(name, "__") ? 1 : 0
		};
	}

	/** Whether `identity` is what this place gives in `sources`. */
	public function reads(identity:HlFunctionIdentity, sources:SourceAnchors):Bool
		return identity.start == start(sources) && identity.end == end(sources) && identity.line == line(sources)
			&& identity.sourcePath == path(sources);

	function path(sources:SourceAnchors):String
		return first < 0 ? "" : sources.path(first);

	function start(sources:SourceAnchors):Int {
		var result = -1;
		for (index in 0...anchors.length) {
			var start = sources.offset(anchors[index]) + starts[index];
			if (result < 0 || start < result)
				result = start;
		}
		return result;
	}

	function end(sources:SourceAnchors):Int {
		var result = -1;
		for (index in 0...anchors.length) {
			var end = sources.offset(anchors[index]) + ends[index];
			if (result < end)
				result = end;
		}
		return result;
	}

	function line(sources:SourceAnchors):Int {
		var result = 0;
		for (index in 0...anchors.length) {
			var line = sources.line(anchors[index]) + lines[index];
			if (result == 0 || line < result)
				result = line;
		}
		return result;
	}
}
