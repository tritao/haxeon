package compiler.hl;

import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;
import runtime.hashlink.HlFunctionVersionTable;
import runtime.hashlink.HlRuntimePatchCode;

/** Haxe-owned publication record for one committed external HLP generation. */
class HlRuntimePatchGeneration {
	public final patch:HlPatch;
	public final envelope:HlPatchEnvelope;
	public final functions:HlFunctionVersionTable;
	public final baseRevision:Int;
	public final revision:Int;
	public final functionStableIds:Array<Int>;
	public final relocationStableIds:Array<Int>;
	public var activeFunctionCount(default, null):Int;

	final code:Null<HlRuntimePatchCode>;

	public function new(patch:HlPatch, envelope:HlPatchEnvelope, functions:HlFunctionVersionTable, ?code:HlRuntimePatchCode, ?activeFunctionCount:Int) {
		if (patch == null || envelope == null || functions == null)
			throw "HashLink runtime patch generations require a patch, envelope, and function versions";
		if (patch.baseRevision != envelope.baseRevision || patch.revision != envelope.revision)
			throw "HashLink runtime patch generation envelope does not match its patch";
		this.patch = patch.copy();
		this.envelope = {
			moduleId: envelope.moduleId.sub(0, envelope.moduleId.length),
			baseRevision: envelope.baseRevision,
			revision: envelope.revision,
			functionStableIds: envelope.functionStableIds.copy(),
			relocationStableIds: envelope.relocationStableIds.copy()
		};
		this.functions = functions;
		baseRevision = envelope.baseRevision;
		revision = envelope.revision;
		functionStableIds = envelope.functionStableIds.copy();
		relocationStableIds = envelope.relocationStableIds.copy();
		var initialActiveFunctionCount = activeFunctionCount == null ? functionStableIds.length : activeFunctionCount;
		if (initialActiveFunctionCount < 0 || initialActiveFunctionCount > functionStableIds.length)
			throw "HashLink runtime patch generation has an invalid active function count";
		this.activeFunctionCount = initialActiveFunctionCount;
		this.code = code;
	}

	/** Whether every function supplied by this generation has since been replaced. */
	public var isRetired(get, never):Bool;

	function get_isRetired():Bool
		return activeFunctionCount == 0;

	/** Return the native revision while the committed generation owns its code. */
	public function codeRevision():Int
		return code == null ? -1 : code.revision;

	/** Release the native allocation owned by this generation exactly once. */
	@:allow(compiler.hl.HlLoadedRuntimeModule, compiler.hl.HlRuntimePatchLedger)
	function releaseCode():Bool
		return code == null || code.release();

	/** Transfer one stable function identity to a newer generation. */
	@:allow(compiler.hl.HlRuntimePatchLedger)
	function replaceFunction():Void {
		if (activeFunctionCount == 0)
			throw "HashLink runtime patch generation has no active functions to retire";
		activeFunctionCount--;
	}

	/** Return an isolated diagnostic snapshot of this committed generation. */
	public function snapshot():HlRuntimePatchGeneration
		return new HlRuntimePatchGeneration(patch, envelope, functions, null, activeFunctionCount);
}
