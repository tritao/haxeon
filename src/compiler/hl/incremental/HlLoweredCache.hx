package compiler.hl.incremental;

import compiler.hl.lower.HlDebugMetadataCache;

/**
 * The lowered functions of the last plain build, by name, for the next one (see `HlLoweredFunction`), with the debugger metadata
 * memoized for them. It belongs to the compiler session like the other caches and follows the candidate build: a failed build
 * leaves the earlier entries in place.
 */
class HlLoweredCache {
	/**
	 * The entries, by function name. A copy shares the map, so it is replaced as a whole (as lowering does) or through
	 * `setEntry`, never changed in place.
	 */
	public var entries:Map<String, HlLoweredFunction> = [];

	/** Whether `entries` may be shared with a copy, so that `setEntry` copies it first. */
	var entriesShared = false;

	/** Identities and opcode spans of functions whose IR and code did not change. */
	public final debug:HlDebugMetadataCache;

	/** The numbers of the requests the entries made (`HlLoweredFunction.keys`), shared by the copies: they only grow. */
	public final keys:HlRequestKeys;

	/** The facts the entries read, with their prints (`HlLoweredFunction.facts`), shared by the copies like `keys`. */
	public final facts:compiler.hl.lower.HlLoweringView.HlLoweringFacts;

	/** The field stores each final function makes (`IrNonNullFields`), while it is the same object; shared by the copies like `keys`. */
	public final nonNullStores:compiler.ir.analysis.IrNonNullFields.IrFieldStoreMemo;

	/** What the steps around lowering work out from each function alone, shared by the copies like `keys`. */
	public final summaries:HlFunctionSummaries;

	/** Each function's form with its runtime calls through helpers, while its IR is the same object (`IrSharedRuntimeCalls`). */
	public var sharedCalls = new compiler.hl.IrSharedRuntimeCalls.IrSharedCallsMemo();

	/** The tables the entries were linked into, with what made them, for the next build to keep (`HlLinkRecord`). */
	public var tables:Null<HlLinkRecord> = null;

	/** What the entries were lowered for besides their IR (see `HashLinkBackendSession.loweringEnvironment`). */
	public var environment = "";

	public function new(?debug:HlDebugMetadataCache, ?keys:HlRequestKeys,
			?facts:compiler.hl.lower.HlLoweringView.HlLoweringFacts, ?summaries:HlFunctionSummaries,
			?nonNullStores:compiler.ir.analysis.IrNonNullFields.IrFieldStoreMemo) {
		this.nonNullStores = nonNullStores == null
			? new compiler.ir.analysis.IrNonNullFields.IrFieldStoreMemo() : nonNullStores;
		this.summaries = summaries == null ? new HlFunctionSummaries() : summaries;
		this.debug = debug == null ? new HlDebugMetadataCache() : debug;
		this.keys = keys == null ? new HlRequestKeys() : keys;
		this.facts = facts == null ? new compiler.hl.lower.HlLoweringView.HlLoweringFacts() : facts;
	}

	public function copy():HlLoweredCache {
		var result = new HlLoweredCache(debug, keys, facts, summaries, nonNullStores);
		result.entries = entries;
		entriesShared = true;
		result.entriesShared = true;
		result.sharedCalls = sharedCalls.copy();
		result.environment = environment;
		result.tables = tables;
		return result;
	}

	/** Sets the entry of function `name` without changing a map a copy shares. */
	public function setEntry(name:String, entry:HlLoweredFunction):Void {
		if (entriesShared) {
			entries = entries.copy();
			entriesShared = false;
		}
		entries.set(name, entry);
	}

	/** Entries made for another environment are of no use to this one. */
	public function forEnvironment(next:String):Void {
		if (environment == next)
			return;
		entries = [];
		tables = null;
		environment = next;
	}
}
