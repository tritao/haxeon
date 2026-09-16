package runtime;

import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;

/** Haxe-owned publication record for one legacy host HLP generation. */
class RuntimePatchGeneration {
	public final patch:HlPatch;
	public final envelope:HlPatchEnvelope;
	public final functions:RuntimeFunctionVersionTable;
	public final baseRevision:Int;
	public final revision:Int;
	public final functionStableIds:Array<Int>;
	public final relocationStableIds:Array<Int>;
	public var activeFunctionCount(default, null):Int;

	public var isRetired(get, never):Bool;

	public function new(patch:HlPatch, envelope:HlPatchEnvelope, functions:RuntimeFunctionVersionTable) {
		if (patch == null || envelope == null || functions == null)
			throw "Runtime patch generations require a patch, envelope, and function versions";
		if (patch.baseRevision != envelope.baseRevision || patch.revision != envelope.revision)
			throw "Runtime patch generation envelope does not match its patch";
		this.patch = patch.copy();
		this.envelope = {
			moduleId: envelope.moduleId.sub(0, envelope.moduleId.length),
			baseRevision: envelope.baseRevision,
			revision: envelope.revision,
			functionStableIds: envelope.functionStableIds.copy(),
			relocationStableIds: envelope.relocationStableIds.copy()
		};
		this.functions = functions.copy();
		baseRevision = envelope.baseRevision;
		revision = envelope.revision;
		functionStableIds = envelope.functionStableIds.copy();
		relocationStableIds = envelope.relocationStableIds.copy();
		activeFunctionCount = functionStableIds.length;
	}

	function get_isRetired():Bool
		return activeFunctionCount == 0;

	/** Transfer one stable function identity to a newer generation. */
	@:allow(runtime.RuntimePatchLedger)
	function replaceFunction():Void {
		if (activeFunctionCount == 0)
			throw "Runtime patch generation has no active functions to retire";
		activeFunctionCount--;
	}
}
