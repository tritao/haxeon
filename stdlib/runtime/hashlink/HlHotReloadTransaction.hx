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
		baseRevision = stateOwner.revision;
		decision = stateOwner.compatibility(candidate, functions);
		this.structuralReload = structuralReload;
	}

	/** Commit only if no newer generation was published after staging. */
	public function commit():HlHotReloadGeneration {
		requireStaged();
		if (stateOwner.revision != baseRevision)
			throw 'HashLink hot-reload transaction is stale (expected revision $baseRevision, got ${stateOwner.revision})';
		if (!structuralReload)
			switch decision {
				case Compatible:
				case RequiresReload(reason):
					throw 'HashLink hot-reload transaction requires a structural reload: $reason';
			}
		var result = stateOwner.commit(candidate, functions, structuralReload);
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
