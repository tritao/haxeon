package compiler.hl;

import haxe.io.Bytes;

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
	public var state(default, null):HlRuntimePatchTransactionState = Staged;

	public function new(owner:HlLoadedRuntimeModule, bytes:Bytes) {
		if (owner == null || bytes == null)
			throw "HashLink runtime patch transactions require an owner and patch bytes";
		this.owner = owner;
		this.bytes = bytes;
		baseRevision = owner.revision;
	}

	/** Commit this patch only if the owner has not advanced since staging. */
	public function commit():Void {
		requireStaged();
		if (owner.revision != baseRevision)
			throw 'HashLink runtime patch transaction is stale (expected revision $baseRevision, got ${owner.revision})';
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
