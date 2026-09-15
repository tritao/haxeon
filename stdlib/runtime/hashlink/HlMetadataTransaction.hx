package runtime.hashlink;

/** Lifecycle state for one staged Haxe-side metadata publication. */
enum HlMetadataTransactionState {
	Staged;
	Committed;
	RolledBack;
}

/**
	Stages one metadata candidate against a registry revision.

	The transaction owns the candidate until commit. A failed or stale
	transaction can therefore roll its arena back without affecting the current
	publication. A committed candidate transfers ownership to the registry.
*/
class HlMetadataTransaction {
	public final registry:HlMetadataRegistry;
	public final candidate:HlMetadataGeneration;
	public final baseRevision:Int;
	public final decision:HlMetadataDecision;
	public final structuralReload:Bool;
	public var state(default, null):HlMetadataTransactionState = Staged;

	public function new(registry:HlMetadataRegistry, candidate:HlMetadataGeneration, ?structuralReload:Bool = false) {
		if (registry == null)
			throw "HashLink metadata transaction requires a registry";
		this.registry = registry;
		this.candidate = candidate;
		this.baseRevision = registry.revision;
		this.decision = registry.compatibility(candidate);
		this.structuralReload = structuralReload;
	}

	/** Commit the candidate if the registry has not advanced since staging. */
	public function commit():HlMetadataPublication {
		requireStaged();
		if (registry.revision != baseRevision)
			throw 'HashLink metadata transaction is stale (expected revision $baseRevision, got ${registry.revision})';

		var publication:HlMetadataPublication;
		if (structuralReload)
			publication = registry.reload(candidate);
		else
			publication = registry.publish(candidate);
		state = Committed;
		return publication;
	}

	/** Dispose an uncommitted candidate and close this transaction. */
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
				throw "HashLink metadata transaction has already committed";
			case RolledBack:
				throw "HashLink metadata transaction has already rolled back";
		}
	}
}
