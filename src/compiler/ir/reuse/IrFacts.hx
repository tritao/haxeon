package compiler.ir.reuse;

import compiler.ir.pipeline.IrFunctionPass.IrFactSource;

/**
 * The session's table of facts the per-function stage memos read (`IrStageMemo`): a fact is what one stage knows about the
 * program besides the function it rewrites, named by the stage, a kind the stage defines and a key ("callee `f` returns the
 * constant true", "`T` is a value object"). Its value is a number the stage computes (`IrFactSource.fact`); its print is a
 * number that changes exactly when the value does, never given twice, so a memo entry that recorded a fact at a print still
 * holds while the fact has that print.
 *
 * A fact is computed again at most once per stage run, when an entry or a rewrite first asks for it (`begin` starts a run). The
 * copies of the session state share the table, as they share the memos: a print names one value whatever build made it.
 *
 * As a build starts (`startBuild`), the facts no entry read in the last build are dropped, with the texts only they had interned
 * (`sweep`): an entry kept since (a stage that did not run) holds a dropped fact at no print, so it is made again. A dropped
 * fact's number is given to the next new one, whose prints are new, so no entry that held the old fact holds the new one.
 */
@:nullSafety(Strict)
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

	/** The space of each fact (`space`), and the last build that read it; a dropped fact's space is -1. */
	final spaceOf:Array<Int> = [];

	final read:Array<Int> = [];

	/** The numbers of dropped facts, which new facts take. */
	final free:Array<Int> = [];

	/** The build under way (`startBuild`), and how many facts it and the last one read. */
	var build = 0;

	var readNow = 0;
	var readLast = 0;

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
	 * A table of a compile that keeps no session, which a stage records in as a session's does: what it reads is computed once per
	 * run, and nothing it records is ever checked again.
	 */
	public static function unshared():IrFacts {
		var table = new IrFacts();
		table.begin();
		return table;
	}

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
		var made = free.pop();
		if (made == null) {
			made = keys.length;
			kinds.push(kind);
			keys.push(key);
			values.push(0);
			prints.push(0);
			computed.push(0);
			recorded.push(0);
			spaceOf.push(space);
			read.push(0);
		} else {
			kinds[made] = kind;
			keys[made] = key;
			values[made] = 0;
			prints[made] = 0;
			computed[made] = 0;
			recorded[made] = 0;
			spaceOf[made] = space;
			read[made] = 0;
		}
		table.set(key, made);
		return made;
	}

	/** The print of fact `id` in this run, computing its value with `pass`, the stage the fact belongs to, the first time; 0 for a dropped fact. */
	public function print(id:Int, pass:IrFactSource):Int {
		if (spaceOf[id] < 0)
			return 0;
		if (read[id] != build) {
			read[id] = build;
			readNow++;
		}
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
	public function hold(facts:Array<Int>, pass:IrFactSource):Bool {
		var index = 0;
		while (index < facts.length) {
			if (print(facts[index], pass) != facts[index + 1])
				return false;
			index += 2;
		}
		return true;
	}

	/** Starts session build `number`: what the last build read is kept, and the rest dropped when it is much (`sweep`). */
	public function startBuild(number:Int):Void {
		build = number;
		readLast = readNow;
		readNow = 0;
		if (keys.length - free.length > readLast * 2 + 1024)
			sweep();
	}

	/** Drops the facts the last build did not read, and the interned texts no fact kept has as its value. */
	function sweep():Void {
		var values:Map<Int, Bool> = [];
		for (id in 0...keys.length) {
			if (spaceOf[id] < 0)
				continue;
			if (read[id] >= build - 1) {
				values.set(this.values[id], true);
				continue;
			}
			ids[spaceOf[id]].remove(keys[id]);
			spaceOf[id] = -1;
			keys[id] = "";
			free.push(id);
		}
		var stale = [for (text => number in interned) if (!values.exists(number)) text];
		for (text in stale)
			interned.remove(text);
		var lists = [for (key => list in singles) if (spaceOf[list[0]] < 0 || prints[list[0]] != list[1]) key];
		for (key in lists)
			singles.remove(key);
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
