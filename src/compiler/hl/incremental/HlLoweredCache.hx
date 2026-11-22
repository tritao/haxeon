package compiler.hl.incremental;

import compiler.hl.lower.HlDebugMetadataCache;

/**
 * The lowered functions of the last plain build, by name, for the next one (see `HlLoweredFunction`), with the debugger metadata
 * memoized for them. It belongs to the compiler session like the other caches and follows the candidate build: a failed build
 * leaves the earlier entries in place.
 */
class HlLoweredCache {
	public var entries:Map<String, HlLoweredFunction> = [];

	/** Identities and opcode spans of functions whose IR and code did not change. */
	public final debug:HlDebugMetadataCache;

	/** The numbers of the requests the entries made (`HlLoweredFunction.keys`), shared by the copies: they only grow. */
	public final keys:HlRequestKeys;

	/** The facts the entries read, with their prints (`HlLoweredFunction.facts`), shared by the copies like `keys`. */
	public final facts:compiler.hl.lower.HlLoweringView.HlFactPrints;

	/** What the steps around lowering work out from each function alone, shared by the copies like `keys`. */
	public final summaries:HlFunctionSummaries;

	/** Each function's form with its runtime calls through helpers, while its IR is the same object (`IrSharedRuntimeCalls`). */
	public var sharedCalls = new compiler.hl.IrSharedRuntimeCalls.IrSharedCallsMemo();

	/** What the entries were lowered for besides their IR (see `HashLinkBackendSession.loweringEnvironment`). */
	public var environment = "";

	public function new(?debug:HlDebugMetadataCache, ?keys:HlRequestKeys,
			?facts:compiler.hl.lower.HlLoweringView.HlFactPrints, ?summaries:HlFunctionSummaries) {
		this.summaries = summaries == null ? new HlFunctionSummaries() : summaries;
		this.debug = debug == null ? new HlDebugMetadataCache() : debug;
		this.keys = keys == null ? new HlRequestKeys() : keys;
		this.facts = facts == null ? new compiler.hl.lower.HlLoweringView.HlFactPrints() : facts;
	}

	public function copy():HlLoweredCache {
		var result = new HlLoweredCache(debug, keys, facts, summaries);
		result.entries = [for (name => entry in entries) name => entry];
		result.sharedCalls = sharedCalls.copy();
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
