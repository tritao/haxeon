package compiler.hl;

import compiler.hl.patch.HlPatch;
import compiler.hl.patch.HlPatch.HlPatchEnvelope;
import runtime.hashlink.HlFunctionVersionTable;

/** Haxe-owned publication record for one committed external HLP generation. */
class HlRuntimePatchGeneration {
	public final patch:HlPatch;
	public final envelope:HlPatchEnvelope;
	public final functions:HlFunctionVersionTable;
	public final baseRevision:Int;
	public final revision:Int;
	public final functionStableIds:Array<Int>;
	public final relocationStableIds:Array<Int>;

	public function new(patch:HlPatch, envelope:HlPatchEnvelope, functions:HlFunctionVersionTable) {
		if (patch == null || envelope == null || functions == null)
			throw "HashLink runtime patch generations require a patch, envelope, and function versions";
		if (patch.baseRevision != envelope.baseRevision || patch.revision != envelope.revision)
			throw "HashLink runtime patch generation envelope does not match its patch";
		this.patch = patch;
		this.envelope = envelope;
		this.functions = functions;
		baseRevision = envelope.baseRevision;
		revision = envelope.revision;
		functionStableIds = envelope.functionStableIds.copy();
		relocationStableIds = envelope.relocationStableIds.copy();
	}
}
