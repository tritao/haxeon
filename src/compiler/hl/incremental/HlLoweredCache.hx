package compiler.hl.incremental;

/**
 * The lowered functions of the last plain build, by name, for the next one (see `HlLoweredFunction`). It belongs to the compiler session like the other caches and follows the candidate build: a failed build
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

	/** The numbers of the requests the entries made (`HlLoweredFunction.keys`), shared by the copies: they only grow. */
	public final keys:HlRequestKeys;

	/** The facts the entries read, with their prints (`HlLoweredFunction.facts`), shared by the copies like `keys`. */
	public final facts:compiler.hl.lower.HlLoweringView.HlLoweringFacts;

	/** The tables the last build's functions were relocated into, for the next to extend (`HlLoweredTables`). */
	public var tables:Null<HlLoweredTables> = null;

	/** The module sections the last plain build wrote, for the next to keep the ones it writes alike (`HlSectionWriter`). */
	public var sections:Null<compiler.hl.HlSectionWriter.HlSectionCache> = null;

	/** What the entries were lowered for besides their IR (see `HashLinkBackendSession.loweringEnvironment`). */
	public var environment = "";

	public function new(?keys:HlRequestKeys, ?facts:compiler.hl.lower.HlLoweringView.HlLoweringFacts) {
		this.keys = keys == null ? new HlRequestKeys() : keys;
		this.facts = facts == null ? new compiler.hl.lower.HlLoweringView.HlLoweringFacts() : facts;
	}

	public function copy():HlLoweredCache {
		var result = new HlLoweredCache(keys, facts);
		result.entries = entries;
		entriesShared = true;
		result.entriesShared = true;
		result.environment = environment;
		result.tables = tables;
		result.sections = sections;
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

/**
 * The tables a build lowered and relocated its functions into, with the answers its requests got and its String
 * constants. A sectioned build names entries by key, so their order is no one's concern: the next build with the same metadata
 * and function layout extends these tables instead of making its own, and every request answered here keeps its answer, so a
 * function kept from here asks nothing. Entries no function names any more stay until a build starts afresh.
 */
class HlLoweredTables {
	/** How long the tables were as the metadata left them, before any function's requests. */
	final metadata:compiler.hl.incremental.HlSymbolTable.HlTableLengths;

	/** The function layout: the name in each slot. */
	final slots:Array<String>;

	public final tables:HlSymbolTable;
	public final answers:HlRequestAnswers;
	public final constants:Array<compiler.hl.HlCode.HlConstant>;

	/**
	 * Which run of builds extending one another's tables these are: within one, an index names the same entry in every build,
	 * as nothing an entry is changes once made (`HlRelocations.chain`).
	 */
	public final chain:Int;

	public function new(metadata:compiler.hl.incremental.HlSymbolTable.HlTableLengths, slots:Array<String>,
			tables:HlSymbolTable, answers:HlRequestAnswers, constants:Array<compiler.hl.HlCode.HlConstant>, chain:Int) {
		this.chain = chain;
		this.metadata = metadata;
		this.slots = slots;
		this.tables = tables;
		this.answers = answers;
		this.constants = constants;
	}

	/** Whether `symbols`, the tables as this build's metadata left them, and the layout `slots` are the ones these extend. */
	public function fits(symbols:HlSymbolTable, slots:Array<String>):Bool
		return symbols != tables && compiler.ir.model.Ir.IrObjectTools.sameNames(slots, this.slots)
			&& HlSymbolTable.sameLengths(symbols.lengths(), metadata) && tables.startsWith(symbols);
}
