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

	/** The dense number of this name among the names of functions (`functionKey`); -1 before one is given. */
	var knownFunctionKey = -1;

	@:processWide("how many names of functions are numbered (`functionKey`), written under the lock")
	static var functionKeys = 0;

	@:processWide("the names of functions by their number (`functionKey`): the list only grows")
	static final byFunctionKey:Array<IrSymbol> = [];

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

	/**
	 * A dense number for this name as the name of a function, given the first time a table keyed by function asks for it: the
	 * stages' memos (`IrStageQueries`) are columns by this number, which counts only the names of functions, not every name the
	 * IR refers to.
	 */
	public inline function functionKey():Int
		return knownFunctionKey >= 0 ? knownFunctionKey : giveFunctionKey();

	function giveFunctionKey():Int {
		lock.acquire();
		if (knownFunctionKey < 0) {
			knownFunctionKey = functionKeys++;
			byFunctionKey.push(this);
		}
		lock.release();
		return knownFunctionKey;
	}

	/** The number `functionKey` gave this name, or -1 when none was asked for: no function was keyed by it. */
	public inline function givenFunctionKey():Int
		return knownFunctionKey;

	/** The symbol for `name` when the name was seen, else null: unlike `of`, it interns nothing. */
	public static function known(name:String):Null<IrSymbol> {
		lock.acquire();
		var symbol = byName.get(name);
		lock.release();
		return symbol;
	}

	/** The symbol whose `functionKey` is `key`. */
	public static function ofFunctionKey(key:Int):IrSymbol
		return byFunctionKey[key];

	public function toString():String
		return name;
}
