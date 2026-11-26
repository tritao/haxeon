package compiler.ir.reuse;

import compiler.ir.pipeline.IrFunctionPass.IrFactSource;
import compiler.query.QueryDatabase;
import compiler.query.QueryKind.QueryKindBase;
import compiler.query.QueryKind.QueryRead;

/**
 * What the per-function stages read about the program besides the function they rewrite, as one kind of the session's query
 * database: a fact is a stage's space (`run`), a kind the stage defines and a key ("callee `f` returns the constant true", "`T` is
 * a value object"), interned to a dense id, and its value is a number the stage computes from its whole-program step
 * (`IrFactSource.fact`). A rewrite reads it through the database (`IrFactReader.read`), so the memo of what the stage made of a
 * function holds while every fact it read has the value it read (docs/design/QUERY_ENGINE.md, the stage driver).
 *
 * A fact is computed at most once per run of its stage, when a rewrite first reads it or a verification first reaches it, and
 * changes when its value does: the engine's change revisions are what the prints of the facts were. A compile that keeps no session
 * reads its facts without a database, computed once per run all the same.
 *
 * A fact no build read since the last sweep is dropped, and its id given to the next new fact, which counts as changed when first
 * computed, so a memo that read the old fact does not hold over the new one.
 */
class IrStageFacts extends QueryKindBase {
	/** A value never equal to itself: a fact the stage cannot state per key, so every memo that read it is computed again. */
	public static inline final UNKNOWN = -0x7fffffff;

	/** By space and kind (`run`, `id`), the id of each key's fact. */
	final ids:Array<Array<Map<String, Int>>> = [];

	final spaces:Map<String, Int> = [];
	final spaceNames:Array<String> = [];

	/** By space, the stage that computes its facts in the run under way, and the run. */
	final sources:Array<Null<IrFactSource>> = [];

	final runs:Array<Int> = [];

	/** By fact: its space (-1 for a dropped fact), kind, key and value, and the run of its space it was computed in. */
	final spaceOf:Array<Int> = [];

	final kinds:Array<Int> = [];
	final keys:Array<String> = [];
	final values:Array<Int> = [];
	final computedIn:Array<Int> = [];

	/** The revision of the database each space's run started in. */
	final runRevisions:Array<Int> = [];

	final free:Array<Int> = [];
	var lastRun = 0;

	/** The last revision a fact was read or verified at: a sweep leaves the kind alone when no build used it since. */
	var usedAt = 0;

	/** The texts `intern` numbered: a fact whose value is a whole-program choice the stage spells out takes the text's number. */
	final interned:Map<String, Int> = [];

	var lastInterned = 0;

	public function new()
		super("ir-stage-facts");

	/**
	 * Starts a run of `stage`, whose facts `source` computes from here on: each is computed again when next read. Returns the
	 * stage's space. A stage that runs again in the revision it ran in starts a revision of its own, so what the earlier run's
	 * facts verified does not hold over this run's.
	 */
	public function run(database:Null<QueryDatabase>, stage:String, source:IrFactSource):Int {
		var space = spaces.get(stage);
		if (space == null) {
			space = ids.length;
			ids.push([]);
			spaceNames.push(stage);
			sources.push(null);
			runs.push(0);
			runRevisions.push(0);
			spaces.set(stage, space);
		}
		sources[space] = source;
		source.space = space;
		runs[space] = ++lastRun;
		if (database != null) {
			if (runRevisions[space] == database.revision)
				database.advance();
			runRevisions[space] = database.revision;
		}
		return space;
	}

	/** The id of the fact `key` of `kind` in `space`, made the first time it is named. */
	public function id(space:Int, kind:Int, key:String):Int {
		var byKind = ids[space];
		while (byKind.length <= kind)
			byKind.push([]);
		var table = byKind[kind], known = table.get(key);
		if (known != null)
			return known;
		var made = free.pop();
		if (made == null) {
			made = keys.length;
			spaceOf.push(space);
			kinds.push(kind);
			keys.push(key);
			values.push(0);
			computedIn.push(0);
			if (made >= verifiedAt.length) {
				// Lengthened by half again: a build that names many new facts must not copy the columns once per fact.
				var length = made + 1 + (made >> 1);
				QueryRead.extend(verifiedAt, length);
				QueryRead.extend(changes, length);
			}
		} else {
			spaceOf[made] = space;
			kinds[made] = kind;
			keys[made] = key;
			values[made] = 0;
			computedIn[made] = 0;
			verifiedAt[made] = 0;
			changes[made] = 0;
		}
		table.set(key, made);
		return made;
	}

	/** The value of fact `id` in its space's run, recorded as a read of the query being computed, if any. */
	public function read(database:Null<QueryDatabase>, id:Int):Int {
		if (database == null) {
			if (computedIn[id] != runs[spaceOf[id]])
				compute(id, 0);
			return values[id];
		}
		database.record(this, id);
		bring(database, id);
		return values[id];
	}

	override public function changedAt(database:QueryDatabase, key:Int):Int {
		if (key >= spaceOf.length || spaceOf[key] < 0)
			return database.revision;
		bring(database, key);
		return changes[key];
	}

	/** Brings fact `id` up to date: computed once per run of its space, changed when its value is not the one kept. */
	inline function bring(database:QueryDatabase, id:Int):Void {
		var revision = database.revision;
		usedAt = revision;
		if (verifiedAt[id] != revision || computedIn[id] != runs[spaceOf[id]])
			compute(id, revision);
	}

	function compute(id:Int, revision:Int):Void {
		var space = spaceOf[id], source = sources[space];
		if (source == null)
			throw new compiler.core.InternalError("fact " + describe(id) + " is read before its stage ran");
		var value = source.fact(kinds[id], keys[id]), known = verifiedAt[id] != 0 || changes[id] != 0;
		computedIn[id] = runs[space];
		if (!known || value != values[id] || value == UNKNOWN) {
			values[id] = value;
			changes[id] = revision;
		}
		verifiedAt[id] = revision;
	}

	/** A number for `text`, the same every time it is asked for in the session and different for another text. */
	public function intern(text:String):Int {
		var known = interned.get(text);
		if (known != null)
			return known;
		var made = ++lastInterned;
		interned.set(text, made);
		return made;
	}

	override public function describe(key:Int):String
		return key >= spaceOf.length
			|| spaceOf[key] < 0 ? "a dropped fact" : spaceNames[spaceOf[key]] + " " + kinds[key] + " "
			+ keys[key];

	/**
	 * Drops the facts no build read since `since`, when they outnumber those read, and the interned texts no fact kept has as its
	 * value.
	 */
	override public function sweep(since:Int):Int {
		if (usedAt < since)
			return 0;
		// Facts are dropped once those the build did not read are many: a sweep walks every fact and every interned text.
		var live = 0, read = 0;
		for (id in 0...spaceOf.length)
			if (spaceOf[id] >= 0) {
				live++;
				if (verifiedAt[id] >= since)
					read++;
			}
		if (live - read <= read + 1024)
			return 0;
		var dropped = 0, kept:Map<Int, Bool> = [];
		for (id in 0...spaceOf.length) {
			var space = spaceOf[id];
			if (space < 0)
				continue;
			if (verifiedAt[id] >= since) {
				kept.set(values[id], true);
				continue;
			}
			ids[space][kinds[id]].remove(keys[id]);
			spaceOf[id] = -1;
			keys[id] = "";
			verifiedAt[id] = 0;
			free.push(id);
			dropped++;
		}
		if (dropped > 0) {
			var stale = [for (text => number in interned) if (!kept.exists(number)) text];
			for (text in stale)
				interned.remove(text);
		}
		return dropped;
	}
}
