package compiler.hl;

import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;
import runtime.hashlink.HlFunctionVersionTable;
import runtime.hashlink.HlRuntimePatchCode;

/** Haxe-owned revision, function-version, and generation state for one module. */
class HlRuntimePatchState {
	public var revision(default, null):Int;
	public var functions(default, null):HlFunctionVersionTable;
	public final ledger:HlRuntimePatchLedger;

	public function new(revision:Int, functions:HlFunctionVersionTable, ?ledger:HlRuntimePatchLedger) {
		if (revision < 0 || functions == null || functions.generation != revision)
			throw "HashLink runtime patch state requires a matching non-negative revision and function table";
		this.revision = revision;
		this.functions = functions;
		this.ledger = ledger == null ? new HlRuntimePatchLedger() : ledger;
	}

	/** Prepare the next immutable function-version table without publishing it. */
	public function advance(stableIds:Array<Int>, nextRevision:Int):HlFunctionVersionTable
		return functions.advance(stableIds, nextRevision);

	/** Publish one native-successful generation and advance all Haxe policy state. */
	public function publish(patch:HlPatch, envelope:HlPatchEnvelope, nextFunctions:HlFunctionVersionTable, code:HlRuntimePatchCode):Void {
		if (patch == null || envelope == null || nextFunctions == null || code == null)
			throw "HashLink runtime patch state requires a complete publication";
		if (patch.baseRevision != revision
			|| envelope.baseRevision != revision
			|| patch.revision != envelope.revision
			|| nextFunctions.generation != patch.revision)
			throw "HashLink runtime patch state publication is out of order";
		ledger.publish(patch, envelope, nextFunctions, code);
		functions = nextFunctions;
		revision = patch.revision;
	}

	/** Release generation handles during native module teardown. */
	@:allow(compiler.hl.HlLoadedRuntimeModule)
	function releaseAll():Void
		ledger.releaseAll();
}
