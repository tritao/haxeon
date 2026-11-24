package compiler.ir.model;

import compiler.core.InternalError;
import sys.thread.Mutex;

/**
 * A name the IR refers to, such as a call's target, interned: one `IrSymbol` per name, so references compare by identity and
 * a table about symbols is an array indexed by `id`. A symbol exists before what it names is defined; a call may name a
 * runtime native or a helper a later pass generates.
 *
 * Ids are dense and given in the order names are first seen in the process, so they may index tables but must never decide
 * the order of anything a compile writes: iterate in program order and look up by id.
 */
@:nullSafety(Strict)
class IrSymbol {
	@:processWide("interned names: a name always denotes the same symbol, and the table only grows")
	static final byName:Map<String, IrSymbol> = [];

	@:processWide("guards interning, which the compile and census threads may both do")
	static final lock = new Mutex();

	static inline final CHUNK_BITS = 12;
	static inline final CHUNK_SIZE = 1 << CHUNK_BITS;

	/**
	 * The interned symbols by id, in chunks: the outer array is made at its full length and a chunk never moves once made, so
	 * `at`, which every read of a body's names goes through, needs no lock. An id reaches a reader only after `of` stored it.
	 */
	@:processWide("interned names, by id: the chunks only fill")
	static final chunks:Array<Null<Array<IrSymbol>>> = [for (_ in 0...1 << 14) null];

	@:processWide("how many symbols are interned, written under the lock")
	static var count = 0;

	public final id:Int;
	public final name:String;

	function new(id:Int, name:String) {
		this.id = id;
		this.name = name;
	}

	/** The symbol for `name`, made the first time the name is seen. */
	public static function of(name:String):IrSymbol {
		lock.acquire();
		var symbol = byName.get(name);
		if (symbol == null) {
			var id = count, chunk = chunks[id >> CHUNK_BITS];
			if (chunk == null) {
				if (id >> CHUNK_BITS >= chunks.length) {
					lock.release();
					throw new InternalError('More than ${chunks.length * CHUNK_SIZE} IR symbols');
				}
				chunk = [];
				chunk.resize(CHUNK_SIZE);
				chunks[id >> CHUNK_BITS] = chunk;
			}
			symbol = new IrSymbol(id, name);
			chunk[id & (CHUNK_SIZE - 1)] = symbol;
			byName.set(name, symbol);
			count = id + 1;
		}
		lock.release();
		return symbol;
	}

	/** The symbol with id `id`, which must be one `of` has given. */
	public static function at(id:Int):IrSymbol {
		var chunk = chunks[id >> CHUNK_BITS];
		if (chunk == null)
			throw new InternalError('No IR symbol $id');
		return chunk[id & (CHUNK_SIZE - 1)];
	}

	public function toString():String
		return name;
}
