package runtime.hashlink;

import runtime.hashlink.HlMetadataCompatibility;
import runtime.hashlink.HlMetadataCompatibility.HlMetadataDecision;
import runtime.memory.Mutex;

typedef HlMetadataRegistryStage = {
	final revision:Int;
	final decision:HlMetadataDecision;
}

/**
	Owns the Haxe-side publication and retirement policy for metadata generations.
	Publication and retirement transitions are serialized by a runtime mutex. The
	publication view remains immutable after sealing, while consumers retain it
	through a lease before using its native pointers.
*/
class HlMetadataRegistry {
	var revisionValue:Int = 0;
	public var revision(get, never):Int;
	public var retiredCount(get, never):Int;
	public var retiredBorrowedCount(get, never):Int;

	final publicationMutex:Mutex;
	var current:Null<HlMetadataGeneration>;
	final retired:Array<HlMetadataGeneration> = [];
	var disposed:Bool = false;

	public function new() {
		publicationMutex = Mutex.create();
	}

	function get_revision():Int
		return withLock(function() return revisionValue);

	function get_retiredCount():Int
		return withLock(function() return retired.length);

	function get_retiredBorrowedCount():Int {
		return withLock(function() {
			var count = 0;
			for (generation in retired)
				count += generation.borrowerCount();
			return count;
		});
	}

	/** Check whether a candidate can replace the current generation in place. */
	public function compatibility(candidate:HlMetadataGeneration):HlMetadataDecision {
		return withLock(function() {
			requireOpen();
			return HlMetadataCompatibility.check(current, candidate);
		});
	}

	/** Publish a newly built generation when its type prefix is patch-compatible. */
	public function publish(candidate:HlMetadataGeneration):HlMetadataPublication
		return withLock(function() return publishUnlocked(candidate));

	function publishUnlocked(candidate:HlMetadataGeneration):HlMetadataPublication {
		requireOpen();
		switch HlMetadataCompatibility.check(current, candidate) {
			case Compatible:
			case RequiresReload(reason):
				throw 'HashLink metadata generation requires a structural reload: $reason';
		}
		return commitUnlocked(candidate);
	}

	/**
		Publish a structurally changed generation through the explicit reload path.
		The old generation remains retired until the caller drains it.
	*/
	public function reload(candidate:HlMetadataGeneration):HlMetadataPublication
		return withLock(function() return reloadUnlocked(candidate));

	function reloadUnlocked(candidate:HlMetadataGeneration):HlMetadataPublication {
		requireOpen();
		switch HlMetadataCompatibility.check(current, candidate) {
			case Compatible if (current != null):
				throw "HashLink metadata generation is compatible; use publish instead of reload";
			case Compatible:
			case RequiresReload(_):
		}
		return commitUnlocked(candidate);
	}

	function commitUnlocked(candidate:HlMetadataGeneration):HlMetadataPublication {
		if (candidate == current)
			throw "HashLink metadata generation is already current";
		candidate.publish();
		return adoptPublishedUnlocked(candidate);
	}

	/** Adopt a pre-published candidate after another policy layer has prepared it. */
	@:allow(runtime.hashlink.HlHotReloadState)
	function adoptPublished(candidate:HlMetadataGeneration):HlMetadataPublication
		return withLock(function() return adoptPublishedUnlocked(candidate));

	function adoptPublishedUnlocked(candidate:HlMetadataGeneration):HlMetadataPublication {
		if (candidate == current)
			throw "HashLink metadata generation is already current";
		if (!candidate.isPublished())
			throw "HashLink metadata generation must be published before adoption";
		var publication = candidate.snapshot(), previous = current;
		current = candidate;
		if (previous != null)
			retired.push(previous);
		revisionValue++;
		return publication;
	}

	/** Capture a transaction decision and revision under one publication lock. */
	@:allow(runtime.hashlink.HlMetadataTransaction)
	function stage(candidate:HlMetadataGeneration):HlMetadataRegistryStage {
		return withLock(function() {
			requireOpen();
			return {
				revision: revisionValue,
				decision: HlMetadataCompatibility.check(current, candidate)
			};
		});
	}

	/** Commit a transaction only if its staged decision is still current. */
	@:allow(runtime.hashlink.HlMetadataTransaction)
	function commitTransaction(transaction:HlMetadataTransaction):HlMetadataPublication {
		return withLock(function() {
			requireOpen();
			if (revisionValue != transaction.baseRevision)
				throw 'HashLink metadata transaction is stale (expected revision ${transaction.baseRevision}, got $revisionValue)';
			return transaction.structuralReload ? reloadUnlocked(transaction.candidate) : publishUnlocked(transaction.candidate);
		});
	}

	/** Return the current stable publication view. */
	public function currentPublication():HlMetadataPublication {
		return withLock(function() {
			requireOpen();
			if (current == null)
				throw "HashLink metadata registry has no published generation";
			return current.snapshot();
		});
	}

	/** Borrow the current publication until the returned lease is released. */
	public function currentLease():HlMetadataLease {
		return withLock(function() {
			requireOpen();
			if (current == null)
				throw "HashLink metadata registry has no published generation";
			return current.acquire();
		});
	}

	/** Dispose unborrowed generations that have been superseded and return their count. */
	public function disposeRetired():Int {
		return withLock(function() {
			requireOpen();
			var count = 0, remaining:Array<HlMetadataGeneration> = [];
			for (generation in retired)
				if (generation.disposeIfUnborrowed())
					count++;
				else
					remaining.push(generation);
			retired.resize(0);
			for (generation in remaining)
				retired.push(generation);
			return count;
		});
	}

	/** Dispose the current and all retired generations. Repeated disposal is safe. */
	public function dispose():Void {
		publicationMutex.acquire();
		try {
			if (disposed) {
				publicationMutex.release();
				return;
			}
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
			publicationMutex.release();
		} catch (error:Dynamic) {
			publicationMutex.release();
			throw error;
		}
	}

	function withLock<T>(operation:Void->T):T {
		publicationMutex.acquire();
		try {
			var result = operation();
			publicationMutex.release();
			return result;
		} catch (error:Dynamic) {
			publicationMutex.release();
			throw error;
		}
	}

	function requireOpen():Void {
		if (disposed)
			throw "HashLink metadata registry has been disposed";
	}
}
