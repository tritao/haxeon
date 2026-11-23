package compiler.ir.reuse;

import compiler.ir.model.IrFunction;
import haxe.ds.ObjectMap;

/**
 * What a whole-program step after the IR stages worked out from one function alone (its signature text, the classes and globals
 * it names, the runtime natives it calls), kept while the function is the same object: an `IrFunction` is never changed once
 * made, so the same object gives the same answer. A step that scans every function each build asks here first and scans only the
 * functions it has not seen, which on an edit are the few the edit made.
 *
 * Entries live one build past their last use (`endBuild`), so a long session holds what the last build had, not every function an
 * edit replaced. A failed build only leaves entries of functions that exist, which are as good as any.
 */
@:nullSafety(Strict)
class IrFunctionMemo<V> {
	var current = new ObjectMap<IrFunction, V>();
	var last = new ObjectMap<IrFunction, V>();

	public function new() {}

	public function get(fn:IrFunction):Null<V> {
		var value = current.get(fn);
		if (value == null) {
			value = last.get(fn);
			if (value != null)
				current.set(fn, value);
		}
		return value;
	}

	public inline function set(fn:IrFunction, value:V):Void
		current.set(fn, value);

	/** Forgets every entry, for a compile that keeps no session: their keys would keep the functions alive. */
	public function clear():Void {
		current = new ObjectMap();
		last = new ObjectMap();
	}

	/** Drops what the build that just ended did not ask for. */
	public function endBuild():Void {
		last = current;
		current = new ObjectMap();
	}
}
