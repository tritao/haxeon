package compiler.hl.incremental;

import compiler.ir.hl.HlDebugMetadataCache;

/**
 * The lowered functions of the last plain build, by name, for the next one (see `HlLoweredFunction`), with the debugger metadata
 * memoized for them. It belongs to the compiler session like the other caches and follows the candidate build: a failed build
 * leaves the earlier entries in place.
 */
class HlLoweredCache {
	public var entries:Map<String, HlLoweredFunction> = [];

	/** Identities and opcode spans of functions whose IR and code did not change. */
	public final debug:HlDebugMetadataCache;

	/** What the entries were lowered for besides their IR (see `BackendAssembly.loweringEnvironment`). */
	public var environment = "";

	public function new(?debug:HlDebugMetadataCache)
		this.debug = debug == null ? new HlDebugMetadataCache() : debug;

	public function copy():HlLoweredCache {
		var result = new HlLoweredCache(debug);
		result.entries = [for (name => entry in entries) name => entry];
		result.environment = environment;
		return result;
	}

	/** Entries made for another environment are of no use to this one. */
	public function forEnvironment(next:String):Void {
		if (environment == next)
			return;
		entries = [];
		environment = next;
	}
}
