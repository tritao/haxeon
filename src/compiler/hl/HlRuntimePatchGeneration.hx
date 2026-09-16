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

	final code:Null<HlRuntimePatchCode>;

	public function new(patch:HlPatch, envelope:HlPatchEnvelope, functions:HlFunctionVersionTable, ?code:HlRuntimePatchCode) {
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
		this.code = code;
	}

	/** Return the native revision while the committed generation owns its code. */
	public function codeRevision():Int
		return code == null ? -1 : code.revision;

	/** Release the native allocation owned by this generation exactly once. */
	@:allow(compiler.hl.HlLoadedRuntimeModule)
	function releaseCode():Bool
		return code == null || code.release();

	/** Return an isolated diagnostic snapshot of this committed generation. */
	public function snapshot():HlRuntimePatchGeneration
		return new HlRuntimePatchGeneration(patch, envelope, functions);
}
