package compiler.ir;

import sys.thread.Mutex;

/**
 * A name the IR refers to, such as a call's target, interned: one `IrSymbol` per name, so references compare by identity and
 * a table about symbols is an array indexed by `id`. A symbol exists before what it names is defined; a call may name a
 * runtime native or a helper a later pass generates.
 *
 * Ids are dense and given in the order names are first seen in the process, so they may index tables but must never decide
 * the order of anything a compile writes: iterate in program order and look up by id.
 */
class IrSymbol {
	@:processWide("interned names: a name always denotes the same symbol, and the table only grows")
	static final byName:Map<String, IrSymbol> = [];

	@:processWide("interned names, by id: the table only grows")
	static final byId:Array<IrSymbol> = [];

	@:processWide("guards the interning tables, which the compile and census threads may both reach")
	static final lock = new Mutex();

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
			symbol = new IrSymbol(byId.length, name);
			byId.push(symbol);
			byName.set(name, symbol);
		}
		lock.release();
		return symbol;
	}

	/** The symbol with id `id`, which must be one `of` has given. */
	public static function at(id:Int):IrSymbol {
		lock.acquire();
		var symbol = byId[id];
		lock.release();
		return symbol;
	}

	/** How many symbols exist: every id is below it, so it sizes a table indexed by id. */
	public static function count():Int {
		lock.acquire();
		var result = byId.length;
		lock.release();
		return result;
	}

	public function toString():String
		return name;
}
