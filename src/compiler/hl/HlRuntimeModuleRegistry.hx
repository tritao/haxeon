package compiler.hl;

import haxe.io.Bytes;
import runtime.memory.Mutex;

/**
	Owns the Haxe-side publication and retirement policy for Haxe-built runtime
	modules. Native HashLink remains responsible for quiescing and releasing one
	module; this registry keeps failed retirement attempts reachable for retry.
 */
class HlRuntimeModuleRegistry {
	public var generation(get, never):Int;
	public var retiredCount(get, never):Int;
	public var retiredBorrowedCount(get, never):Int;

	final registryMutex:Mutex;
	var generationValue:Int = 0;
	var current:Null<HlLoadedRuntimeModule>;
	final retired:Array<HlLoadedRuntimeModule> = [];
	var disposed:Bool = false;

	public function new() {
		registryMutex = Mutex.create();
	}

	function get_generation():Int
		return withLock(function() return generationValue);

	function get_retiredCount():Int
		return withLock(function() return retired.length);

	function get_retiredBorrowedCount():Int {
		return withLock(function() {
			var count = 0;
			for (module in retired)
				count += module.borrowerCount();
			return count;
		});
	}

	/** Return the currently published runtime module, or null before the first load. */
	public function currentModule():Null<HlLoadedRuntimeModule> {
		return withLock(function() {
			requireOpen();
			return current;
		});
	}

	/** Borrow the current module until the returned lease is released. */
	public function currentLease():HlRuntimeModuleLease {
		return withLock(function() {
			requireOpen();
			if (current == null)
				throw "HashLink runtime module registry has no published module";
			return current.acquire();
		});
	}

	/** Load a Haxe-built module and publish it as the current generation. */
	public function loadRuntime(bytes:Bytes, identity:Bytes):HlLoadedRuntimeModule {
		return withLock(function() {
			requireOpen();
			var candidate = HlNativeModuleLoader.loadRuntime(bytes, identity);
			try {
				publishUnlocked(candidate);
				return candidate;
			} catch (error:Dynamic) {
				if (!candidate.unload())
					retired.push(candidate);
				throw error;
			}
		});
	}

	/** Publish an already initialized candidate and retire the previous module. */
	public function publish(candidate:HlLoadedRuntimeModule):Void {
		withLock(function() publishUnlocked(candidate));
	}

	function publishUnlocked(candidate:HlLoadedRuntimeModule):Void {
		requireOpen();
		if (candidate == null || !candidate.isLoaded())
			throw "HashLink runtime module registry requires a loaded candidate";
		if (candidate == current)
			throw "HashLink runtime module registry candidate is already current";
		var previous = current;
		current = candidate;
		generationValue++;
		if (previous != null) {
			previous.beginRetirement();
			retired.push(previous);
		}
	}

	/** Dispose unborrowed retired modules and return the number reclaimed. */
	public function disposeRetired():Int {
		return withLock(function() {
			requireOpen();
			return disposeRetiredUnlocked();
		});
	}

	/** Dispose the current and retired modules once all borrowers have released. */
	public function dispose():Void {
		withLock(function() {
			if (disposed)
				return;
			if (current != null && !current.unload())
				throw "HashLink current runtime module could not be unloaded";
			current = null;
			var pending = retired.length;
			if (disposeRetiredUnlocked() != pending)
				throw "HashLink retired runtime modules could not be unloaded";
			retired.resize(0);
			disposed = true;
		});
	}

	function disposeRetiredUnlocked():Int {
		var count = 0, remaining:Array<HlLoadedRuntimeModule> = [];
		for (module in retired)
			if (module.unload())
				count++;
			else
				remaining.push(module);
		retired.resize(0);
		for (module in remaining)
			retired.push(module);
		return count;
	}

	function requireOpen():Void {
		if (disposed)
			throw "HashLink runtime module registry has been disposed";
	}

	function withLock<T>(operation:Void->T):T {
		registryMutex.acquire();
		try {
			var result = operation();
			registryMutex.release();
			return result;
		} catch (error:Dynamic) {
			registryMutex.release();
			throw error;
		}
	}
}
