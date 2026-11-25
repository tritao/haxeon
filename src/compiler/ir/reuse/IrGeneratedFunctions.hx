package compiler.ir.reuse;

import compiler.ir.model.IrFunction;

/**
 * Functions generated from parts of the typed program rather than from a unit of their own (the anonymous structures' printers,
 * the static initializers' parts), each kept by key with the objects it was made from, its inputs. A build that would make one
 * from the same objects takes the kept function instead, so the IR stages see the function object they saw before
 * (`IrLineage.start`); one whose inputs changed is made again, as a fresh build makes it. An input is an object never changed
 * once made (a typed field kept while its unit is current, an `IrObject`), so the same object is the same input; a function
 * whose key says all it is made of has none.
 *
 * `--check-reuse` (`checks`) makes every kept function again and compares the two.
 */
@:nullSafety(Strict)
class IrGeneratedFunctions<T> {
	/** `--check-reuse`: each kept function is made again and compared with the fresh one. */
	public var checks = false;

	final functions:Map<String, IrFunction> = [];
	final inputs:Map<String, Array<T>> = [];

	/** By key, the last `sweep` round that took or made the function. */
	final used:Map<String, Int> = [];

	var round = 1;

	public function new() {}

	/** The function of `key` made from `from`: the kept one when it was made from the same objects, else `make()`, kept. */
	public function made(key:String, from:Array<T>, make:() -> IrFunction):IrFunction {
		var fn = kept(key, from);
		if (fn != null) {
			if (checks && !compiler.ir.codec.IrFunctionStateEquality.same(fn, make()))
				throw new compiler.core
					.InternalError('--check-reuse: the generated function kept as "$key" differs from one made again from the same inputs');
			return fn;
		}
		var made = make();
		keep(key, from, made);
		return made;
	}

	/** The function of `key` when it was made from the same objects as `from`, or null. */
	public function kept(key:String, from:Array<T>):Null<IrFunction> {
		var known = inputs.get(key);
		if (known == null || known.length != from.length)
			return null;
		for (index in 0...from.length)
			if (known[index] != from[index])
				return null;
		used.set(key, round);
		return functions.get(key);
	}

	/** Keeps `fn` as the function of `key`, made from `from`. */
	public function keep(key:String, from:Array<T>, fn:IrFunction):Void {
		functions.set(key, fn);
		inputs.set(key, from);
		used.set(key, round);
	}

	/** Drops the functions nothing took or made since the last sweep: the program no longer has their inputs. */
	public function sweep():Void {
		var stale = [for (key => last in used) if (last != round) key];
		for (key in stale) {
			functions.remove(key);
			inputs.remove(key);
			used.remove(key);
		}
		round++;
	}

	/**
	 * Drops every function, in place: a compile that keeps no session lets them go before its passes, and the state it was copied
	 * from shares this one (`SessionState.initializerFunctions`).
	 */
	public function clear():Void {
		functions.clear();
		inputs.clear();
		used.clear();
	}

	/** A copy with the same entries, which `keep` on either does not change in the other. */
	public function copy():IrGeneratedFunctions<T> {
		var result = new IrGeneratedFunctions<T>();
		for (key => fn in functions) {
			result.functions.set(key, fn);
			result.inputs.set(key, inputs.get(key) ?? []);
			result.used.set(key, used.get(key) ?? 0);
		}
		result.round = round;
		return result;
	}
}
