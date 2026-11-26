package compiler.query;

import compiler.core.InternalError;
import compiler.query.QueryKind.QueryKindBase;
import compiler.query.QueryKind.QueryRead;

/**
 * A whole-program step's summary over per-key contributions (`docs/design/QUERY_ENGINE.md`, Whole-program steps): each
 * contributor, such as a function, names the keys it contributes (the closure types it makes, the array types it names), and
 * the summary holds which keys some contributor names. A reader reads one key (`has`), so a key that appears or goes changes
 * only that key's readers; or the whole set (`keys`), which changes with any of them.
 *
 * A stage gives every contributor's contribution in each run, between `open` and `close`. A contribution that is the array it
 * gave last run (a memo that held) costs nothing, and a changed one is applied key by key, so a run updates the summary in the
 * time of what changed. A contribution that is a function of a contributor's input alone (what a function names, by the
 * function's key) needs no memo: `holds` keeps it while the input has not changed since it was given. A contributor not given
 * in a run is retracted when it closes. The summary is read after `close`.
 *
 * As a read, key `k` is `k + 1`, and 0 is the whole set. Between runs the summary is settled (`QueryKindBase.changeIfVerified`):
 * the revision each read last changed at is in `changes`, which a verification reads without a call.
 */
class QuerySummary extends QueryKindBase {
	final keyName:Null<Int->String>;

	/** How many contributions name each key. */
	final counts:Array<Int> = [];

	/**
	 * By contributor, its contribution, the run that gave it, the revision it was given at (0 for none), and what it was given from
	 * (`holdsFrom`).
	 */
	final contributions:Array<Null<Array<Int>>> = [];

	final givenIn:Array<Int> = [];

	final givenAt:Array<Int> = [];

	final givenFrom:Array<Int> = [];

	var contributors = 0;
	var run = 0;
	var given = 0;
	var opened = false;

	/** By key, the last replacement whose old contribution names it (`replace`). */
	final inOld:Array<Int> = [];

	var replacement = 0;

	/** How many contributions were applied key by key since the summary was made: those that were not the ones kept. */
	public var replaced(default, null) = 0;

	public function new(name:String, ?keyName:Int->String) {
		super(name);
		this.keyName = keyName;
		changes.push(0);
		settled = true;
	}

	/** Starts a run of contributions. A run left open by a build that stopped is started again: what it gave stays given. */
	public function open(database:QueryDatabase):Void {
		opened = true;
		settled = false;
		run++;
		given = 0;
	}

	/**
	 * Gives `contributor`'s contribution: the keys it names, never changed once given. The same array as last run is the same
	 * contribution. `from`, when not 0, names what it was made of (`holdsFrom`).
	 */
	public function contribute(database:QueryDatabase, contributor:Int, keys:Array<Int>, from = 0):Void {
		if (!opened)
			throw new InternalError("summary " + kindName + " takes contributions only while open");
		if (contributor >= givenIn.length) {
			var length = contributor + 1 + (contributor >> 1);
			QueryRead.extend(givenIn, length);
			QueryRead.extend(givenAt, length);
			QueryRead.extend(givenFrom, length);
			contributions.resize(length);
		}
		markGiven(contributor);
		givenAt[contributor] = database.revision;
		givenFrom[contributor] = from;
		var old = contributions[contributor];
		if (old == keys)
			return;
		if (old == null)
			contributors++;
		contributions[contributor] = keys;
		replace(database.revision, old, keys);
	}

	/**
	 * Keeps `contributor`'s contribution in this run, as if given again, when it was given from what `input` holds for the same key
	 * as it stands now: that has not changed since. Brings `input`'s key up to date. A stage whose contributions are each made of
	 * its input this way makes and gives one only where this is false; with `--check-reuse` it makes every one and compares.
	 */
	public function holds(database:QueryDatabase, contributor:Int, input:QueryKindBase):Bool {
		if (!opened)
			throw new InternalError("summary " + kindName + " takes contributions only while open");
		if (contributor >= givenAt.length)
			return false;
		var at = givenAt[contributor];
		if (at == 0)
			return false;
		var change = input.changeIfVerified(contributor, database.revision);
		if (change < 0)
			change = input.changedAt(database, contributor);
		if (change > at)
			return false;
		markGiven(contributor);
		return true;
	}

	/**
	 * Keeps `contributor`'s contribution in this run, as if given again, when it was given from `from` (`contribute`), a number
	 * that names what it is made of, such as the version of the function it was read from (`IrFunction.version`).
	 */
	public function holdsFrom(database:QueryDatabase, contributor:Int, from:Int):Bool {
		if (!opened)
			throw new InternalError("summary " + kindName + " takes contributions only while open");
		if (from == 0 || contributor >= givenFrom.length || givenFrom[contributor] != from || givenAt[contributor] == 0)
			return false;
		markGiven(contributor);
		return true;
	}

	/** The contribution `contributor` gave last, or null. */
	public function contribution(contributor:Int):Null<Array<Int>>
		return contributor < contributions.length ? contributions[contributor] : null;

	inline function markGiven(contributor:Int):Void {
		if (givenIn[contributor] == run)
			throw new InternalError("summary " + kindName + " is given contributor " + contributor
				+ " twice in one run");
		givenIn[contributor] = run;
		given++;
	}

	/** Ends the run: the contributors it did not give are retracted. `--check-reuse` counts keys again from the contributions. */
	public function close(database:QueryDatabase):Void {
		if (!opened)
			throw new InternalError("summary " + kindName + " is closed without being open");
		if (given < contributors)
			for (contributor in 0...contributions.length) {
				var old = contributions[contributor];
				if (old != null && givenIn[contributor] != run) {
					contributions[contributor] = null;
					givenAt[contributor] = 0;
					givenFrom[contributor] = 0;
					contributors--;
					replace(database.revision, old, null);
				}
			}
		opened = false;
		settled = true;
		if (database.checkReuse)
			checkCounts();
	}

	/** Whether some contributor names `key`, recorded as a read of that key. */
	public function has(database:QueryDatabase, key:Int):Bool {
		readable();
		database.record(this, key + 1);
		return key < counts.length && counts[key] > 0;
	}

	/**
	 * The keys some contributor names, in key order, recorded as a read of the whole set. Keys that are interned ids (`IrSymbol`,
	 * `IrTypeIds`) must not decide the order of what a stage outputs: it orders them as the program does.
	 */
	public function keys(database:QueryDatabase):Array<Int> {
		readable();
		database.record(this, 0);
		return [for (key in 0...counts.length) if (counts[key] > 0) key];
	}

	override public function changedAt(database:QueryDatabase, key:Int):Int {
		readable();
		return key < changes.length ? changes[key] : 0;
	}

	override public function describe(key:Int):String
		return kindName + "(" + (key == 0 ? "all" : keyName == null ? Std.string(key - 1) : keyName(key - 1)) + ")";

	inline function readable():Void
		if (opened)
			throw new InternalError("summary " + kindName + " is read while its contributions are open");

	/** Replaces contribution `old` with `keys` (either null for none): a key whose count leaves or reaches 0 changes. */
	function replace(revision:Int, old:Null<Array<Int>>, keys:Null<Array<Int>>):Void {
		replaced++;
		var mark = ++replacement;
		if (old != null)
			for (key in old) {
				counts[key]--;
				inOld[key] = mark;
			}
		if (keys != null)
			for (key in keys) {
				if (key >= counts.length) {
					var length = key + 1 + (key >> 1);
					QueryRead.extend(counts, length);
					QueryRead.extend(changes, length + 1);
					QueryRead.extend(inOld, length);
				}
				if (counts[key]++ == 0 && inOld[key] != mark)
					changed(key, revision);
			}
		if (old != null)
			for (key in old)
				if (counts[key] == 0)
					changed(key, revision);
	}

	inline function changed(key:Int, revision:Int):Void {
		changes[key + 1] = revision;
		changes[0] = revision;
	}

	function checkCounts():Void {
		var expected:Array<Int> = [];
		QueryRead.extend(expected, counts.length);
		for (contribution in contributions)
			if (contribution != null)
				for (key in contribution)
					if (key < expected.length)
						expected[key]++;
					else
						throw new InternalError("--check-reuse: summary " + kindName
							+ " has a contribution naming a key it never counted: a contribution changed after it was given");
		for (key in 0...counts.length)
			if (counts[key] != expected[key])
				throw new InternalError("--check-reuse: summary " + describe(key + 1) + " counts " + counts[key]
					+ " contributions, but they name it " + expected[key]
					+ " times: a contribution changed after it was given");
	}
}
