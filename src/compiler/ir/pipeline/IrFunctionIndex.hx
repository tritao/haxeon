package compiler.ir.pipeline;

import compiler.ir.analysis.IrEntryPrune;
import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrSymbol;

/**
 * A pass's by-name view of the function list. After the early prune (`IrEntryPrune`) a lookup of a name the prune removed is a
 * decision made on a function that is no longer there; with `--check-reuse` it throws, naming the pass and the name. A pass that
 * needs a function the prune would remove must ask for it by (type, operation) through `IrProviders` instead, so the walk reaches it.
 */
class IrFunctionIndex {
	final pass:String;

	/** By the number of each function's name (`IrSymbol.functionKey`), the function: no table of names is made per pass. */
	final byKey:Array<Null<IrFunction>> = [];

	/** The functions to index on the first lookup. */
	var pending:Null<Array<IrFunction>>;

	public function new(pass:String, functions:Array<IrFunction>) {
		this.pass = pass;
		pending = functions;
	}

	/** Indexes the functions given at construction, when that is still to do. */
	function flush():Void {
		var waiting = pending;
		if (waiting != null) {
			pending = null;
			// Every function's key is below the count of keys given: one allocation, not one per growth.
			if (byKey.length == 0)
				byKey.resize(IrSymbol.functionKeysGiven());
			for (fn in waiting)
				put(fn.symbol.functionKey(), fn);
		}
	}

	inline function put(key:Int, fn:IrFunction):Void {
		if (key >= byKey.length)
			byKey.resize(key + 1 + (key >> 1));
		byKey[key] = fn;
	}

	function find(name:String):Null<IrFunction> {
		flush();
		var symbol = IrSymbol.known(name);
		var key = symbol == null ? -1 : symbol.givenFunctionKey();
		return key >= 0 && key < byKey.length ? byKey[key] : null;
	}

	public function get(name:String):Null<IrFunction> {
		var fn = find(name);
		if (fn == null)
			IrEntryPrune.noteLookup(pass, name);
		return fn;
	}

	public function exists(name:String):Bool {
		var found = find(name) != null;
		if (!found)
			IrEntryPrune.noteLookup(pass, name);
		return found;
	}

	public function set(name:String, fn:IrFunction):Void {
		flush();
		put(IrSymbol.of(name).functionKey(), fn);
	}
}
