package runtime.hashlink;

/**
	Owns the Haxe-side publication and retirement policy for metadata generations.
	The registry is intentionally single-threaded until the runtime gains atomic
	publication primitives.
*/
class HlMetadataRegistry {
	public var revision(default, null):Int = 0;
	public var retiredCount(get, never):Int;

	var current:Null<HlMetadataGeneration>;
	final retired:Array<HlMetadataGeneration> = [];
	var disposed:Bool = false;

	function get_retiredCount():Int
		return retired.length;

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
		var publication = candidate.publish(), previous = current;
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

	/** Dispose all generations that have been superseded and return their count. */
	public function disposeRetired():Int {
		requireOpen();
		var count = retired.length;
		for (generation in retired)
			generation.dispose();
		retired.resize(0);
		return count;
	}

	/** Dispose the current and all retired generations. Repeated disposal is safe. */
	public function dispose():Void {
		if (disposed)
			return;
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
