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

	/** Publish a newly built generation after its metadata has been initialized. */
	public function publish(candidate:HlMetadataGeneration):HlMetadataPublication {
		requireOpen();
		if (candidate == null)
			throw "HashLink metadata registry cannot publish a null generation";
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
