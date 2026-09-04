package runtime;

import haxe.io.Bytes;

class PatchSet {
	public final baseRevision:Int;
	public final revision:Int;
	public final bytes:Bytes;
	public final changedFunctions:Array<Int>;
	public final requiresReload:Bool;

	public function new(baseRevision, revision, bytes, changedFunctions, requiresReload) {
		this.baseRevision = baseRevision;
		this.revision = revision;
		this.bytes = bytes;
		this.changedFunctions = changedFunctions;
		this.requiresReload = requiresReload;
	}
}
