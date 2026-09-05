package runtime;

import haxe.io.Bytes;

class PatchSet {
	public final baseRevision:Int;
	public final revision:Int;
	public final bytes:Bytes;
	public final changedFunctions:Array<Int>;

	public function new(baseRevision:Int, revision:Int, bytes:Bytes, changedFunctions:Array<Int>) {
		if (baseRevision < 0 || revision <= baseRevision)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Patch revisions must advance from a non-negative base");
		if (bytes == null || bytes.length == 0 || changedFunctions == null || changedFunctions.length == 0)
			throw new RuntimeError(RuntimeStatus.BadArgument, "Patch artifact and changed functions are required");
		this.baseRevision = baseRevision;
		this.revision = revision;
		this.bytes = bytes;
		this.changedFunctions = changedFunctions.copy();
	}
}
