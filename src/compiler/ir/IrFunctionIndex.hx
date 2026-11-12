package compiler.ir;

import compiler.ir.Ir;

/**
 * A pass's by-name view of the function list. After the early prune (`IrEntryPrune`) a lookup of a name the prune removed is a
 * decision made on a function that is no longer there; with HAXEON_CHECK_REUSE=1 it throws, naming the pass and the name. A pass that
 * needs a function the prune would remove must ask for it by (type, operation) through `IrProviders` instead, so the walk reaches it.
 */
class IrFunctionIndex {
	final pass:String;
	final byName:Map<String, IrFunction> = [];

	public function new(pass:String, functions:Array<IrFunction>) {
		this.pass = pass;
		for (fn in functions)
			byName.set(fn.name, fn);
	}

	public function get(name:String):Null<IrFunction> {
		var fn = byName.get(name);
		if (fn == null)
			IrEntryPrune.noteLookup(pass, name);
		return fn;
	}

	public function exists(name:String):Bool {
		var found = byName.exists(name);
		if (!found)
			IrEntryPrune.noteLookup(pass, name);
		return found;
	}

	public function set(name:String, fn:IrFunction):Void
		byName.set(name, fn);
}
