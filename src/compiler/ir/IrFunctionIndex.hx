package compiler.ir;

import compiler.ir.Ir;

/**
 * A pass's by-name view of the function list. After the early prune (`IrEntryPrune`) a lookup of a name the prune removed is a
 * decision made on a function that is no longer there; with `--check-reuse` it throws, naming the pass and the name. A pass that
 * needs a function the prune would remove must ask for it by (type, operation) through `IrProviders` instead, so the walk reaches it.
 */
class IrFunctionIndex {
	final pass:String;
	final byName:Map<String, IrFunction> = [];

	/**
	 * In a session before the encode point, the program's shared name index (`IrLineage.named`), for `functions` that are the
	 * program as the stages stand: names are looked up there, and `byName` holds only what the pass sets.
	 */
	final lineage:Null<compiler.ir.IrStageMemo.IrLineage>;

	/** The functions to index on the first lookup, when there is no shared index. */
	var pending:Null<Array<IrFunction>>;

	public function new(pass:String, functions:Array<IrFunction>, ?lineage:compiler.ir.IrStageMemo.IrLineage) {
		this.pass = pass;
		this.lineage = lineage;
		if (lineage == null)
			pending = functions;
		else if (lineage.checks)
			lineage.checkIndex(pass, functions);
	}

	/** Indexes the functions given at construction, when that is still to do. */
	function flush():Void {
		var waiting = pending;
		if (waiting != null) {
			pending = null;
			for (fn in waiting)
				byName.set(fn.name, fn);
		}
	}

	function find(name:String):Null<IrFunction> {
		flush();
		var fn = byName.get(name), shared = lineage;
		if (fn == null && shared != null)
			fn = shared.named(name);
		return fn;
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
		byName.set(name, fn);
	}
}
