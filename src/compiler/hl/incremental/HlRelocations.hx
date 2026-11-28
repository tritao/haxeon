package compiler.hl.incremental;

import compiler.core.InternalError;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;

/**
 * The functions of a sectioned build (`HlCode.relocations`), each kept as the build that lowered it made it: its code names
 * entries by the indices that build's tables gave its requests (`HlLoweredFunction.answers`), and this says where this build's
 * tables hold them. So a function whose IR and outside facts are the same stays the same object from build to build, however the
 * tables number now, and a section whose functions and entries read the same is kept (`HlSectionWriter`).
 */
class HlRelocations {
	/** By position in the module's functions, the lowered function, its requests with the answers its code uses. */
	public final lowered:Array<HlLoweredFunction>;

	/** By position, the function's index in this build's layout. */
	public final functionIndices:Array<Int>;

	/** By position, the index of the function's type in this build's tables. */
	public final functionTypes:Array<Int>;

	/** By position, whether some index the function's code uses is another in this build's tables (`fill`). */
	public final moves:Array<Bool>;

	/** The answers the build's requests got, which say where moved indices are; null for identity relocations (`identity`). */
	final answers:Null<HlRequestAnswers>;

	/**
	 * The run of builds whose tables this build's extend (`HlLoweredTables.chain`): an index of a table names the same entry in
	 * every build of one run, so what a section named in one it names in the others.
	 */
	public final chain:Int;

	public function new(lowered:Array<HlLoweredFunction>, functionIndices:Array<Int>, functionTypes:Array<Int>,
			moves:Array<Bool>, answers:Null<HlRequestAnswers>, chain:Int) {
		this.chain = chain;
		this.lowered = lowered;
		this.functionIndices = functionIndices;
		this.functionTypes = functionTypes;
		this.moves = moves;
		this.answers = answers;
	}

	/**
	 * The relocations of a live build's functions: the live tables only grow within a module identity and never renumber, so each
	 * function keeps its slot and every index its code uses, and one run of builds (`chain`) lasts while the layout does.
	 */
	public static function identity(lowered:Array<HlLoweredFunction>, chain:Int):HlRelocations {
		var indices:Array<Int> = [], types:Array<Int> = [], moves:Array<Bool> = [];
		for (entry in lowered) {
			indices.push(entry.fn.functionIndex);
			types.push(entry.fn.type);
			moves.push(false);
		}
		return new HlRelocations(lowered, indices, types, moves, null, chain);
	}

	/** Fills `remap` with where this build's tables hold each index the function at `position` uses. */
	public function fill(position:Int, remap:HlRemap):Void {
		var known = answers;
		if (known == null)
			throw new InternalError('HashLink sections: ${lowered[position].name} has identity relocations');
		var conflict = HlLink.fill(lowered[position], known, remap);
		if (conflict != null)
			throw new InternalError('HashLink sections: ${lowered[position].name} was kept although $conflict');
	}

	/** The function at `position` with this build's indices, for a reader of the dense module: itself when none moved. */
	public function materialize(position:Int, remap:HlRemap):HlFunction {
		var fn = lowered[position].fn;
		if (!moves[position] && functionIndices[position] == fn.functionIndex)
			return fn;
		fill(position, remap);
		return HlLink.rewritten(fn, functionIndices[position], remap);
	}
}

/**
 * The tables a build lowered and relocated its functions into, with the answers its requests got and its String
 * constants. A sectioned build names entries by key, so their order is no one's concern: the next build with the same settings,
 * metadata and function layout extends these tables instead of making its own, and every request answered here keeps its answer, so a
 * function kept from here asks nothing. Entries no function names any more stay until a build starts afresh.
 */
class HlLoweredTables {
	/** How long the tables were as the metadata left them, before any function's requests. */
	final metadata:compiler.hl.incremental.HlSymbolTable.HlTableLengths;

	/** The function layout: the name in each slot. */
	final slots:Array<String>;

	/** The settings the functions were lowered with (`HlLower.settings`). */
	final settings:String;

	public final tables:HlSymbolTable;
	public final answers:HlRequestAnswers;
	public final constants:Array<compiler.hl.HlCode.HlConstant>;

	/**
	 * Which run of builds extending one another's tables these are: within one, an index names the same entry in every build,
	 * as nothing an entry is changes once made (`HlRelocations.chain`).
	 */
	public final chain:Int;

	public function new(metadata:compiler.hl.incremental.HlSymbolTable.HlTableLengths, slots:Array<String>,
			settings:String,
			tables:HlSymbolTable, answers:HlRequestAnswers, constants:Array<compiler.hl.HlCode.HlConstant>, chain:Int) {
		this.chain = chain;
		this.settings = settings;
		this.metadata = metadata;
		this.slots = slots;
		this.tables = tables;
		this.answers = answers;
		this.constants = constants;
	}

	/**
	 * Whether `symbols`, the tables as this build's metadata left them, the layout `slots` and `settings` are the ones these
	 * extend.
	 */
	public function fits(symbols:HlSymbolTable, slots:Array<String>, settings:String):Bool
		return symbols != tables && settings == this.settings
			&& compiler.ir.model.Ir.IrObjectTools.sameNames(slots, this.slots)
			&& HlSymbolTable.sameLengths(symbols.lengths(), metadata) && tables.startsWith(symbols);
}
