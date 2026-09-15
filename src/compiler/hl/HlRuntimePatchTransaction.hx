package compiler.hl;

import haxe.io.Bytes;
import compiler.hl.patch.HlPatchHeaderReader;

/** Lifecycle state for one staged external-runtime HLP transaction. */
enum HlRuntimePatchTransactionState {
	Staged;
	Committed;
	RolledBack;
}

/**
	Stages one HLP update against a Haxe-built runtime module.

	The transaction owns policy state until commit. Native HashLink remains the
	publication mechanism and guarantees that a failed commit leaves the live
	generation untouched.
 */
class HlRuntimePatchTransaction {
	public final owner:HlLoadedRuntimeModule;
	public final bytes:Bytes;
	public final baseRevision:Int;
	public final patchBaseRevision:Int;
	public final patchRevision:Int;
	public var state(default, null):HlRuntimePatchTransactionState = Staged;

	public function new(owner:HlLoadedRuntimeModule, bytes:Bytes) {
		if (owner == null || bytes == null)
			throw "HashLink runtime patch transactions require an owner and patch bytes";
		this.owner = owner;
		this.bytes = bytes.sub(0, bytes.length);
		baseRevision = owner.revision;
		var header:{moduleId:Bytes, baseRevision:Int, revision:Int};
		try {
			header = HlPatchHeaderReader.decode(this.bytes);
		} catch (error:Dynamic) {
			throw 'Haxeon rejected the HLP transaction: ${Std.string(error)}';
		}
		if (header.moduleId.compare(owner.identity.moduleId) != 0)
			throw "Haxeon rejected an HLP transaction for another module";
		patchBaseRevision = header.baseRevision;
		patchRevision = header.revision;
	}

	/** Commit this patch only if the owner has not advanced since staging. */
	public function commit():Void {
		requireStaged();
		if (owner.revision != baseRevision)
			throw 'HashLink runtime patch transaction is stale (expected revision $baseRevision, got ${owner.revision})';
		if (patchBaseRevision != baseRevision)
			throw 'HashLink runtime patch transaction has the wrong base revision (expected $baseRevision, got $patchBaseRevision)';
		owner.patch(bytes);
		state = Committed;
	}

	/** Discard an uncommitted patch transaction. */
	public function rollback():Void {
		if (state == Staged)
			state = RolledBack;
	}

	function requireStaged():Void {
		switch state {
			case Staged:
			case Committed:
				throw "HashLink runtime patch transaction has already committed";
			case RolledBack:
				throw "HashLink runtime patch transaction has already rolled back";
		}
	}
}
