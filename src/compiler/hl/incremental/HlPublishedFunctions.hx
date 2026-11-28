package compiler.hl.incremental;

/**
 * The functions of the module a live build published, by name, as lowered for its slots, with the sections it wrote: what the
 * next live build keeps without lowering again (`HlLower.trustCache`) and patches against. It follows the assembler, so a refused
 * publication takes it back with it.
 */
class HlPublishedFunctions {
	/**
	 * The entries, by function name. A copy shares the map, so it is replaced as a whole (as lowering does) or through
	 * `setEntry`, never changed in place.
	 */
	public var entries:Map<String, HlLoweredFunction> = [];

	/** Whether `entries` may be shared with a copy, so that `setEntry` copies it first. */
	var entriesShared = false;

	/** The module sections the last live build wrote, for the next to keep the ones it writes alike (`HlSectionWriter`). */
	public var sections:Null<compiler.hl.HlSectionWriter.HlSectionCache> = null;

	public function new() {}

	public function copy():HlPublishedFunctions {
		var result = new HlPublishedFunctions();
		result.entries = entries;
		entriesShared = true;
		result.entriesShared = true;
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
}
