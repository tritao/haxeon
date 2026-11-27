package compiler.ir.reuse;

/**
 * What an answer fact is worked out from (`IrFacts.printAnswer`): an answer the source keeps per fact, typed as it is, and
 * compares with the one it kept by kind. An answer is a part of the program (an object, a signature, a type), compared part by
 * part, never by its text. A class, not an interface: HashLink calls an interface through a virtual made at each conversion.
 */
class IrAnswerSource {
	function new() {}

	/**
	 * Works the answer of fact `id` (of `kind` and `key`) out as the program stands, keeps it for `id`, and returns whether it is the
	 * same as the one kept before; `known` is false when no answer is kept for `id` yet.
	 */
	public function settle(id:Int, kind:Int, key:String, known:Bool):Bool
		throw new compiler.core.InternalError("An answer source works its answers out");
}

/**
 * A table of facts with prints, the one a memo outside the query engine checks what it read against: HashLink lowering's
 * (`HlLoweringView`); the per-function stages, the inliner and verification read theirs through the engine (`IrStageFacts`). A fact is what one reader knows about the program besides the function it works on, named by a space (a stage
 * and a kind it defines) and a key. Its value is an answer compared per kind (`IrAnswerSource`); its print is a number that changes
 * exactly when the answer does, never given twice, so a memo entry that recorded a fact at a print still holds while the fact has
 * that print.
 *
 * A fact is worked out again at most once per stage run, when an entry or a reader first asks for it (`begin` starts a run). The
 * copies of the session state share the table, as they share the memos: a print names one value whatever build made it.
 *
 * As a build starts (`startBuild`), the facts no entry read in the last build are dropped (`sweep`): an entry kept since (a stage
 * that did not run) holds a dropped fact at no print, so it is made again. A dropped fact's number is given to the next new one,
 * whose prints are new, so no entry that held the old fact holds the new one.
 */
@:nullSafety(Strict)
class IrFacts {
	/** By stage and kind (`space`), the number of each key's fact. */
	final ids:Array<Map<String, Int>> = [];

	final spaces:Map<String, Int> = [];
	final kinds:Array<Int> = [];
	final keys:Array<String> = [];
	final prints:Array<Int> = [];

	/** The name of each space, for `describe`. */
	final spaceNames:Array<String> = [];

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
		spaceNames.push(name);
		spaces.set(name, made);
		return made;
	}

	/** The fact `key` of `space`, made the first time it is named. `kind` is the stage's own kind, which its answer source is given. */
	public function id(space:Int, kind:Int, key:String):Int {
		var table = ids[space], known = table.get(key);
		if (known != null)
			return known;
		var made = free.pop();
		if (made == null) {
			made = keys.length;
			kinds.push(kind);
			keys.push(key);
			prints.push(0);
			computed.push(0);
			recorded.push(0);
			spaceOf.push(space);
			read.push(0);
		} else {
			kinds[made] = kind;
			keys[made] = key;
			prints[made] = 0;
			computed[made] = 0;
			recorded[made] = 0;
			spaceOf[made] = space;
			read[made] = 0;
		}
		table.set(key, made);
		return made;
	}

	/**
	 * The print of answer fact `id` in this run, working its answer out with `source` the first time: a new print when the answer
	 * is not the same as the one the print was made for; 0 for a dropped fact.
	 */
	public function printAnswer(id:Int, source:IrAnswerSource):Int {
		if (spaceOf[id] < 0)
			return 0;
		if (read[id] != build) {
			read[id] = build;
			readNow++;
		}
		if (computed[id] != run) {
			computed[id] = run;
			if (!source.settle(id, kinds[id], keys[id], prints[id] != 0))
				prints[id] = ++lastPrint;
		}
		return prints[id];
	}

	/** What fact `id` is about, for a message. */
	public function describe(id:Int):String
		return spaceOf[id] < 0 ? "a dropped fact" : spaceNames[spaceOf[id]] + " " + keys[id];

	/** Starts a build: what the last build read is kept, and the rest dropped when it is much (`sweep`). */
	public function startBuild():Void {
		build++;
		run++;
		readLast = readNow;
		readNow = 0;
		if (keys.length - free.length > readLast * 2 + 1024)
			sweep();
	}

	/** Drops the facts the last build did not read. */
	function sweep():Void
		for (id in 0...keys.length) {
			if (spaceOf[id] < 0 || read[id] >= build - 1)
				continue;
			ids[spaceOf[id]].remove(keys[id]);
			spaceOf[id] = -1;
			keys[id] = "";
			free.push(id);
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
