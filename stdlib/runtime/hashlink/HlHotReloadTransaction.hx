package runtime.hashlink;

/** Lifecycle state for one staged hot-reload policy transaction. */
enum HlHotReloadTransactionState {
	Staged;
	Committed;
	RolledBack;
}

/**
	Stages metadata and stable function-version policy together.

	The candidate remains owned by the transaction until commit. Stale or rejected
	transactions can therefore roll their metadata arena back without changing the
	live generation.
*/
class HlHotReloadTransaction {
	public final stateOwner:HlHotReloadState;
	public final candidate:HlMetadataGeneration;
	public final functions:HlFunctionVersionTable;
	public final baseRevision:Int;
	public final decision:HlHotReloadDecision;
	public final structuralReload:Bool;
	public var state(default, null):HlHotReloadTransactionState = Staged;

	public function new(stateOwner:HlHotReloadState, candidate:HlMetadataGeneration, functions:HlFunctionVersionTable,
			?structuralReload:Bool = false) {
		if (stateOwner == null)
			throw "HashLink hot-reload transaction requires an owner";
		this.stateOwner = stateOwner;
		this.candidate = candidate;
		this.functions = functions;
		var staged = stateOwner.stageCandidate(candidate, functions);
		baseRevision = staged.revision;
		decision = staged.decision;
		this.structuralReload = structuralReload;
	}

	/** Commit only if no newer generation was published after staging. */
	public function commit():HlHotReloadGeneration {
		requireStaged();
		var result = stateOwner.commitTransaction(this);
		state = Committed;
		return result;
	}

	/** Commit after initializing a native HashLink module for the candidate. */
	public function commitNative(?flags:Int = 0):HlHotReloadGeneration {
		requireStaged();
		var result = stateOwner.commitNativeTransaction(this, flags);
		state = Committed;
		return result;
	}

	/** Dispose an uncommitted metadata candidate and close this transaction. */
	public function rollback():Void {
		if (state != Staged)
			return;
		candidate.dispose();
		state = RolledBack;
	}

	function requireStaged():Void {
		switch state {
			case Staged:
			case Committed:
				throw "HashLink hot-reload transaction has already committed";
			case RolledBack:
				throw "HashLink hot-reload transaction has already rolled back";
		}
	}

}
