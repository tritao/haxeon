package runtime.hashlink;

/**
	Owns the Haxe-side publication and retirement policy for metadata generations.
	The registry is intentionally single-threaded until the runtime gains atomic
	publication primitives.
*/
class HlMetadataRegistry {
	public var revision(default, null):Int = 0;
	public var retiredCount(get, never):Int;
	public var retiredBorrowedCount(get, never):Int;

	var current:Null<HlMetadataGeneration>;
	final retired:Array<HlMetadataGeneration> = [];
	var disposed:Bool = false;

	function get_retiredCount():Int
		return retired.length;

	function get_retiredBorrowedCount():Int {
		var count = 0;
		for (generation in retired)
			count += generation.borrowerCount();
		return count;
	}

	/** Check whether a candidate can replace the current generation in place. */
	public function compatibility(candidate:HlMetadataGeneration):HlMetadataDecision {
		requireOpen();
		return HlMetadataCompatibility.check(current, candidate);
	}

	/** Publish a newly built generation when its type prefix is patch-compatible. */
	public function publish(candidate:HlMetadataGeneration):HlMetadataPublication {
		requireOpen();
		switch compatibility(candidate) {
			case Compatible:
			case RequiresReload(reason):
				throw 'HashLink metadata generation requires a structural reload: $reason';
		}
		return commit(candidate);
	}

	/**
		Publish a structurally changed generation through the explicit reload path.
		The old generation remains retired until the caller drains it.
	*/
	public function reload(candidate:HlMetadataGeneration):HlMetadataPublication {
		requireOpen();
		switch compatibility(candidate) {
			case Compatible if (current != null):
				throw "HashLink metadata generation is compatible; use publish instead of reload";
			case Compatible:
			case RequiresReload(_):
		}
		return commit(candidate);
	}

	function commit(candidate:HlMetadataGeneration):HlMetadataPublication {
		if (candidate == current)
			throw "HashLink metadata generation is already current";
		candidate.publish();
		return adoptPublished(candidate);
	}

	/** Adopt a pre-published candidate after another policy layer has prepared it. */
	@:allow(runtime.hashlink.HlHotReloadState)
	function adoptPublished(candidate:HlMetadataGeneration):HlMetadataPublication {
		if (candidate == current)
			throw "HashLink metadata generation is already current";
		if (!candidate.isPublished())
			throw "HashLink metadata generation must be published before adoption";
		var publication = candidate.snapshot(), previous = current;
		current = candidate;
		if (previous != null)
			retired.push(previous);
		revision++;
		return publication;
	}

	/** Return the current stable publication view. */
	public function currentPublication():HlMetadataPublication {
		requireOpen();
		if (current == null)
			throw "HashLink metadata registry has no published generation";
		return current.snapshot();
	}

	/** Borrow the current publication until the returned lease is released. */
	public function currentLease():HlMetadataLease {
		requireOpen();
		if (current == null)
			throw "HashLink metadata registry has no published generation";
		return current.acquire();
	}

	/** Dispose unborrowed generations that have been superseded and return their count. */
	public function disposeRetired():Int {
		requireOpen();
		var count = 0, remaining:Array<HlMetadataGeneration> = [];
		for (generation in retired) {
			var borrowerCount = generation.borrowerCount();
			if (borrowerCount == 0) {
				generation.dispose();
				count++;
			} else
				remaining.push(generation);
		}
		retired.resize(0);
		for (generation in remaining)
			retired.push(generation);
		return count;
	}

	/** Dispose the current and all retired generations. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
		for (generation in retired)
			if (generation.borrowerCount() != 0)
				throw "HashLink metadata registry has borrowed retired generations";
		if (current != null && current.borrowerCount() != 0)
			throw "HashLink metadata registry has a borrowed current generation";
		for (generation in retired)
			generation.dispose();
		retired.resize(0);
		if (current != null)
			current.dispose();
		current = null;
		disposed = true;
	}

	function requireOpen():Void {
		if (disposed)
			throw "HashLink metadata registry has been disposed";
	}
}
