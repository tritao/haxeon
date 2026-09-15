package runtime.hashlink;

/** Decision made by Haxe-side hot-reload policy before native publication. */
enum HlHotReloadDecision {
	Compatible;
	RequiresReload(reason:String);
}

/** One published metadata and function-version generation. */
class HlHotReloadGeneration {
	public final revision:Int;
	public final metadata:HlMetadataGeneration;
	public final publication:HlMetadataPublication;
	public final functions:HlFunctionVersionTable;
	public final nativeModule:Null<HlNativeModule>;
	var borrowers:Int = 0;

	@:allow(runtime.hashlink.HlHotReloadState)
	function new(revision:Int, metadata:HlMetadataGeneration, publication:HlMetadataPublication, functions:HlFunctionVersionTable,
			nativeModule:Null<HlNativeModule>) {
		this.revision = revision;
		this.metadata = metadata;
		this.publication = publication;
		this.functions = functions;
		this.nativeModule = nativeModule;
	}

	/** Borrow this generation until the lease is released. */
	public function acquire():HlHotReloadLease
		return new HlHotReloadLease(this);

	public function borrowerCount():Int
		return borrowers;

	@:allow(runtime.hashlink.HlHotReloadLease)
	function retainBorrow():Void
		borrowers++;

	@:allow(runtime.hashlink.HlHotReloadLease)
	function releaseBorrow():Void {
		if (borrowers == 0)
			throw "HashLink hot-reload generation lease count is already zero";
		borrowers--;
	}
}

/**
	Owns Haxe-side hot-reload state and retirement policy.

	This is deliberately single-threaded until atomic publication is available.
	It stages a complete candidate, validates metadata and stable function identity,
	then publishes both as one policy transition. Native commits retain one stable
	dispatch target and hand code-address installation to the small kernel bridge.
*/
class HlHotReloadState {
	public final metadata:HlMetadataRegistry;
	public var revision(default, null):Int = 0;
	public var retiredCount(get, never):Int;
	public var retiredBorrowedCount(get, never):Int;

	var current:Null<HlHotReloadGeneration>;
	final retired:Array<HlHotReloadGeneration> = [];
	var nativePatchTarget:Null<HlNativeModule>;
	final nativePatchOwners:Array<HlNativeModule> = [];
	var disposed:Bool = false;

	public function new(?metadata:HlMetadataRegistry) {
		this.metadata = metadata == null ? new HlMetadataRegistry() : metadata;
		revision = this.metadata.revision;
	}

	function get_retiredCount():Int
		return retired.length;

	function get_retiredBorrowedCount():Int {
		var count = 0;
		for (generation in retired)
			count += generation.borrowerCount();
		return count;
	}

	/** Compare candidate metadata and stable function identities with the live state. */
	public function compatibility(candidate:HlMetadataGeneration, functions:HlFunctionVersionTable):HlHotReloadDecision {
		requireOpen();
		validateFunctionTable(candidate, functions);
		if (current == null)
			return Compatible;
		var metadataDecision = metadata.compatibility(candidate);
		switch metadataDecision {
			case Compatible:
			case RequiresReload(reason):
				return RequiresReload(reason);
		}
		var previousGeneration = current;
		if (previousGeneration == null)
			throw "HashLink hot-reload state lost its current generation";
		var previousFunctions = previousGeneration.functions;
		if (previousFunctions.length() != functions.length())
			return RequiresReload("stable function table changed");
		for (version in previousFunctions.entries()) {
			var next = functions.find(version.stableId);
			if (next == null || next.slot != version.slot)
				return RequiresReload('stable function slot changed for ID ${version.stableId}');
			if (next.typeIndex != version.typeIndex)
				return RequiresReload('stable function signature changed for ID ${version.stableId}');
		}
		return Compatible;
	}

	/** Stage a candidate against the current revision. */
	public function stage(candidate:HlMetadataGeneration, functions:HlFunctionVersionTable, ?structuralReload:Bool = false):HlHotReloadTransaction
		return new HlHotReloadTransaction(this, candidate, functions, structuralReload);

	public function currentGeneration():HlHotReloadGeneration {
		requireOpen();
		if (current == null)
			throw "HashLink hot-reload state has no published generation";
		return current;
	}

	/** Borrow the current metadata and function-version generation. */
	public function currentLease():HlHotReloadLease
		return currentGeneration().acquire();

	/** Return the stable native dispatch target, when native commits are active. */
	public function nativeDispatchModule():Null<HlNativeModule> {
		requireOpen();
		return nativePatchTarget;
	}

	/** Dispose unborrowed superseded generations and return the number reclaimed. */
	public function disposeRetired():Int {
		requireOpen();
		var count = 0, remaining:Array<HlHotReloadGeneration> = [];
		for (generation in retired) {
			if (generation.borrowerCount() == 0 && unloadNativeModule(generation) && generation.metadata.borrowerCount() == 0) {
				count++;
			} else
				remaining.push(generation);
		}
		retired.resize(0);
		for (generation in remaining)
			retired.push(generation);
		metadata.disposeRetired();
		return count;
	}

	/** Dispose the current and retired policy state when no generation is borrowed. */
	public function dispose():Void {
		if (disposed)
			return;
		for (generation in retired)
			if (generation.borrowerCount() != 0)
				throw "HashLink hot-reload state has borrowed retired generations";
		var currentGeneration = current;
		if (currentGeneration != null && currentGeneration.borrowerCount() != 0)
			throw "HashLink hot-reload state has a borrowed current generation";
		if (nativePatchTarget != null) {
			for (index in 0...nativePatchOwners.length) {
				var nativeModule = nativePatchOwners[nativePatchOwners.length - index - 1];
				if (!nativeModule.unload())
					throw "HashLink native hot-reload module could not be unloaded";
			}
			nativePatchOwners.resize(0);
			nativePatchTarget = null;
		} else {
			for (generation in retired)
				if (!unloadNativeModule(generation))
					throw "HashLink native hot-reload module could not be unloaded";
			if (currentGeneration != null && !unloadNativeModule(currentGeneration))
				throw "HashLink native hot-reload module could not be unloaded";
		}
		for (generation in retired)
			if (generation.metadata.borrowerCount() != 0)
				throw "HashLink hot-reload state has borrowed retired metadata";
		if (currentGeneration != null && currentGeneration.metadata.borrowerCount() != 0)
			throw "HashLink hot-reload state has borrowed current metadata";
		metadata.dispose();
		retired.resize(0);
		current = null;
		disposed = true;
	}

	@:allow(runtime.hashlink.HlHotReloadTransaction)
	function commit(candidate:HlMetadataGeneration, functions:HlFunctionVersionTable, structuralReload:Bool):HlHotReloadGeneration {
		requireOpen();
		if (nativePatchTarget != null)
			throw "HashLink native hot-reload state requires native commits after its dispatch target is initialized";
		if (metadata.revision != revision)
			throw 'HashLink metadata registry advanced outside hot-reload state (expected revision $revision, got ${metadata.revision})';
		var publication = structuralReload ? metadata.reload(candidate) : metadata.publish(candidate);
		return finishCommit(candidate, functions, publication, null);
	}

	@:allow(runtime.hashlink.HlHotReloadTransaction)
	function commitNative(candidate:HlMetadataGeneration, functions:HlFunctionVersionTable, flags:Int,
			structuralReload:Bool):HlHotReloadGeneration {
		requireOpen();
		if (nativePatchTarget != null && structuralReload)
			throw "HashLink native structural reload requires a new dispatch target";
		if (metadata.revision != revision)
			throw 'HashLink metadata registry advanced outside hot-reload state (expected revision $revision, got ${metadata.revision})';
		var nativeModule:Null<HlNativeModule> = null;
		try {
			if (!candidate.isPublished())
				candidate.publish();
			nativeModule = new HlNativeModule(candidate, flags | HlNativeModule.PatchableFlag);
			if (nativePatchTarget != null && !nativePatchTarget.patchGeneration(nativeModule))
				throw "HashLink native generation is not patch-compatible with its dispatch target";
			nativePatchOwners.push(nativeModule);
			if (nativePatchTarget == null)
				nativePatchTarget = nativeModule;
			var publication = metadata.adoptPublished(candidate);
			return finishCommit(candidate, functions, publication, nativeModule);
		} catch (error:Dynamic) {
			if (nativeModule != null && !nativeModule.isLoaded())
				nativeModule = null;
			if (nativeModule != null) {
				if (nativePatchOwners.length > 0 && nativePatchOwners[nativePatchOwners.length - 1] == nativeModule)
					nativePatchOwners.pop();
				if (nativePatchTarget == nativeModule)
					nativePatchTarget = null;
				nativeModule.unload();
			}
			candidate.dispose();
			throw error;
		}
	}

	function finishCommit(candidate:HlMetadataGeneration, functions:HlFunctionVersionTable, publication:HlMetadataPublication,
			nativeModule:Null<HlNativeModule>):HlHotReloadGeneration {
		var nextRevision = revision + 1,
			publishedFunctions = functions.withGeneration(nextRevision),
			published = new HlHotReloadGeneration(metadata.revision, candidate, publication, publishedFunctions, nativeModule),
			previous = current;
		current = published;
		revision = metadata.revision;
		if (previous != null)
			retired.push(previous);
		return published;
	}

	function unloadNativeModule(generation:HlHotReloadGeneration):Bool {
		var nativeModule = generation.nativeModule;
		if (nativeModule == null)
			return true;
		for (owner in nativePatchOwners)
			if (owner == nativeModule)
				return false;
		return nativeModule.unload();
	}

	function validateFunctionTable(candidate:HlMetadataGeneration, functions:HlFunctionVersionTable):Void {
		if (candidate == null || functions == null)
			throw "HashLink hot-reload candidates require metadata and function versions";
		var bytecodeCount = candidate.bytecodeFunctionCount();
		if (bytecodeCount > 0 && bytecodeCount != functions.length())
			throw "HashLink metadata and stable function tables have different bytecode lengths";
		if (bytecodeCount == 0 && functions.length() > candidate.functionCount())
			throw "HashLink stable function table is larger than the native dispatch table";
		for (version in functions.entries()) {
			if (version.slot < 0 || version.slot >= candidate.functionCount() || bytecodeCount > 0 && !candidate.isBytecodeFunctionSlot(version.slot))
				throw 'HashLink function slot ${version.slot} is outside the native table';
			if (version.typeIndex >= candidate.typeCount())
				throw 'HashLink function type index ${version.typeIndex} is outside the metadata table';
			var signature = candidate.functionType(version.slot), signatureIndex = candidate.typeIndex(signature);
			if (signatureIndex != version.typeIndex)
				throw 'HashLink function type index mismatch at slot ${version.slot}';
		}
	}

	function requireOpen():Void {
		if (disposed)
			throw "HashLink hot-reload state has been disposed";
	}
}

/** Borrowed view of one hot-reload generation. */
class HlHotReloadLease {
	public final generation:HlHotReloadGeneration;
	public final metadata:HlMetadataLease;
	var released:Bool = false;

	@:allow(runtime.hashlink.HlHotReloadGeneration)
	function new(generation:HlHotReloadGeneration) {
		this.generation = generation;
		generation.retainBorrow();
		try {
			metadata = generation.metadata.acquire();
		} catch (error:Dynamic) {
			generation.releaseBorrow();
			throw error;
		}
	}

	/** Release this borrow. Repeated release is safe. */
	public function release():Void {
		if (released)
			return;
		released = true;
		metadata.release();
		generation.releaseBorrow();
	}

	public inline function isReleased():Bool
		return released;
}
