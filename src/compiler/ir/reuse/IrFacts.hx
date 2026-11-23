package compiler.ir.reuse;

import compiler.ir.pipeline.IrFunctionPass;

/**
 * The session's table of facts the per-function stage memos read (`IrStageMemo`): a fact is what one stage knows about the
 * program besides the function it rewrites, named by the stage, a kind the stage defines and a key ("callee `f` returns the
 * constant true", "`T` is a value object"). Its value is a number the stage computes (`IrFunctionPass.fact`); its print is a
 * number that changes exactly when the value does, never given twice, so a memo entry that recorded a fact at a print still
 * holds while the fact has that print.
 *
 * A fact is computed again at most once per stage run, when an entry or a rewrite first asks for it (`begin` starts a run). The
 * copies of the session state share the table, as they share the memos: a print names one value whatever build made it.
 */
class IrFacts {
	/** A value never equal to itself: a fact the stage cannot state per key, so every entry that read it is recomputed. */
	public static inline final UNKNOWN = -0x7fffffff;

	/** By stage and kind (`space`), the number of each key's fact. */
	final ids:Array<Map<String, Int>> = [];

	final spaces:Map<String, Int> = [];
	final kinds:Array<Int> = [];
	final keys:Array<String> = [];
	final values:Array<Int> = [];
	final prints:Array<Int> = [];

	/** The run each fact was last computed in. */
	final computed:Array<Int> = [];

	/** The reader that last recorded each fact (`IrFactReader`), so a rewrite records a fact once. */
	final recorded:Array<Int> = [];

	var run = 0;
	var lastPrint = 0;
	var lastReader = 0;

	/** The lists of one fact the readers recorded, by fact and print, each kept once (`shared`). */
	final singles:Map<Int, Array<Int>> = [];

	/**
	 * `reads`, a list of facts and their prints a reader recorded, or an equal one recorded before: most rewrites read one fact,
	 * the same one, and their entries share its list.
	 */
	public function shared(reads:Array<Int>):Array<Int> {
		if (reads.length != 2)
			return reads;
		var key = reads[0] * 65599 + reads[1], known = singles.get(key);
		if (known != null && known[0] == reads[0] && known[1] == reads[1])
			return known;
		if (known == null)
			singles.set(key, reads);
		return reads;
	}

	/** By text, the number `intern` gave it. */
	final interned:Map<String, Int> = [];

	var lastInterned = 0;

	public function new() {}

	/**
	 * A number for `text`, the same every time it is asked for in the session and different for another text: a fact whose value is
	 * a whole-program choice the stage spells out (`IrScalarArguments`'s candidates) takes it.
	 */
	public function intern(text:String):Int {
		var known = interned.get(text);
		if (known != null)
			return known;
		var made = ++lastInterned;
		interned.set(text, made);
		return made;
	}

	/** Starts a stage run: every fact is computed again when next asked for. */
	public function begin():Void
		run++;

	/** The number of `stage`'s facts of `kind`, which `id` takes. */
	public function space(stage:String, kind:Int):Int {
		var name = stage + ":" + kind, known = spaces.get(name);
		if (known != null)
			return known;
		var made = ids.length;
		ids.push([]);
		spaces.set(name, made);
		return made;
	}

	/** The fact `key` of `space`, made the first time it is named. `kind` is the stage's own kind, which `pass.fact` is given. */
	public function id(space:Int, kind:Int, key:String):Int {
		var table = ids[space], known = table.get(key);
		if (known != null)
			return known;
		var made = keys.length;
		table.set(key, made);
		kinds.push(kind);
		keys.push(key);
		values.push(0);
		prints.push(0);
		computed.push(0);
		recorded.push(0);
		return made;
	}

	/** The print of fact `id` in this run, computing its value with `pass`, the stage the fact belongs to, the first time. */
	public function print(id:Int, pass:IrFunctionPass):Int {
		if (computed[id] != run) {
			computed[id] = run;
			var value = pass.fact(kinds[id], keys[id]);
			if (prints[id] == 0 || value != values[id] || value == UNKNOWN) {
				values[id] = value;
				prints[id] = ++lastPrint;
			}
		}
		return prints[id];
	}

	/** The value of fact `id`, computed in this run (`print` first). */
	public inline function value(id:Int):Int
		return values[id];

	/** Whether every fact of `facts`, pairs of a fact and the print it was read at, still has its print. */
	public function hold(facts:Array<Int>, pass:IrFunctionPass):Bool {
		var index = 0;
		while (index < facts.length) {
			if (print(facts[index], pass) != facts[index + 1])
				return false;
			index += 2;
		}
		return true;
	}

	/** A number for a new reader, which `firstRead` tells its facts by. */
	public function newReader():Int
		return ++lastReader;

	/** Whether `reader` reads fact `id` for the first time, which it then has. */
	public function firstRead(id:Int, reader:Int):Bool {
		if (recorded[id] == reader)
			return false;
		recorded[id] = reader;
		return true;
	}
}
