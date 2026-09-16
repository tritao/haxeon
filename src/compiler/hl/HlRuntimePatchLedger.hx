package compiler.hl;

import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;
import runtime.hashlink.HlFunctionVersionTable;
import runtime.hashlink.HlRuntimePatchCode;

/**
	Haxe-owned history and retirement policy for external HLP generations.

	Native HashLink still owns executable-memory reclamation and the dispatch
	owner array. This ledger owns the policy view: which generation currently
	provides each stable function, and which committed generations no longer
	provide a live function.
 */
class HlRuntimePatchLedger {
	final committed:Array<HlRuntimePatchGeneration> = [];
	final retired:Array<HlRuntimePatchGeneration> = [];
	final activeOwners:Map<Int, HlRuntimePatchGeneration> = [];

	public var length(get, never):Int;
	public var retiredCount(get, never):Int;

	function get_length():Int
		return committed.length;

	function get_retiredCount():Int
		return retired.length;

	/** Record one successful native publication and update stable-ID ownership. */
	public function publish(patch:HlPatch, envelope:HlPatchEnvelope, functions:HlFunctionVersionTable, code:HlRuntimePatchCode):HlRuntimePatchGeneration {
		var generation = new HlRuntimePatchGeneration(patch, envelope, functions, code);
		for (stableId in generation.functionStableIds) {
			var previous = activeOwners.get(stableId);
			if (previous != null) {
				previous.replaceFunction();
				if (previous.isRetired)
					retired.push(previous);
			}
			activeOwners.set(stableId, generation);
		}
		committed.push(generation);
		return generation;
	}

	/** Return committed patch models without exposing ledger-owned storage. */
	public function patches():Array<HlPatch>
		return [for (generation in committed) generation.patch.copy()];

	/** Return committed generations as isolated diagnostic snapshots. */
	public function snapshots():Array<HlRuntimePatchGeneration>
		return [for (generation in committed) generation.snapshot()];

	/** Return the native revision retained by one committed generation. */
	public function codeRevision(index:Int):Int {
		if (index < 0 || index >= committed.length)
			throw 'HashLink runtime patch generation index $index is unavailable';
		return committed[index].codeRevision();
	}

	/** Return retired generations as isolated diagnostic snapshots. */
	public function retiredSnapshots():Array<HlRuntimePatchGeneration>
		return [for (generation in retired) generation.snapshot()];

	/** Release all native code handles during module teardown. */
	@:allow(compiler.hl.HlLoadedRuntimeModule)
	function releaseAll():Void {
		for (generation in committed)
			if (!generation.releaseCode())
				throw "HashLink external runtime patch-code release failed";
		retired.resize(0);
		for (stableId in activeOwners.keys())
			activeOwners.remove(stableId);
	}
}
