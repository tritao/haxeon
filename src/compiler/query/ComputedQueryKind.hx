package compiler.query;

import compiler.core.InternalError;
import compiler.query.QueryErrors.QueryCycle;
import compiler.query.QueryErrors.QueryReuseMismatch;
import compiler.query.QueryKind.QueryKindBase;
import compiler.query.QueryKind.QueryRead;

/**
 * A kind whose values are too large to digest, such as what a stage made of a function, computed per key: on demand by
 * `compute` when the kind has one, or by a stage in its own run (`current`, `begin`, `end`), as a pass rewrites the program's
 * functions in order. A recomputed value `same` as the one kept keeps that one and the revision it changed at (early cutoff by
 * equality): its readers verify without computing, and a reader that compares by identity finds the object it saw before.
 * Values are compared only where a key was computed again, never digested.
 *
 * The memos are columns by key, so verifying a key whose reads did not change reads a few Ints and allocates nothing: no frame,
 * no handler. A computation that throws ends the build: the next build drops the frames it left (`QueryDatabase.newRevision`), and
 * the marks of the keys it was busy with are of the revision it ended in.
 */
class ComputedQueryKind<V> extends QueryKindBase {
	final same:(V, V) -> Bool;
	final compute:Null<(QueryDatabase, Int) -> V>;
	final keyName:Null<Int->String>;

	// The memos, by key: the value, the revisions it was last verified at (0 for no memo), last changed at and computed at, and
	// what its computation read (`QueryRead`).
	final values:Array<V> = [];
	final verifiedAt:Array<Int> = [];
	final changes:Array<Int> = [];
	final computedAt:Array<Int> = [];
	final reads:Array<Null<Array<Int>>> = [];

	/** By key, the revision in which it is being computed or verified: a read that comes back to it is a cycle. */
	final busy:Array<Int> = [];

	/** The last revision a memo was verified or computed at: a sweep leaves a kind the build did not use alone. */
	var usedAt = 0;

	/**
	 * A kind whose values `compute` makes, reading other queries only through the database, or, without it, that a stage computes
	 * in its own run. A cycle is an error.
	 */
	public function new(name:String, same:(V, V) -> Bool, ?compute:(QueryDatabase, Int) -> V, ?keyName:Int->String) {
		super(name);
		this.same = same;
		this.compute = compute;
		this.keyName = keyName;
	}

	/**
	 * The value of `key`, recorded as a read of the query being computed, if any: computed when its memo does not hold. A kind a
	 * stage computes must have computed or verified it in this revision.
	 */
	public function get(database:QueryDatabase, key:Int):V {
		database.record(this, key);
		var revision = database.revision;
		if (key < busy.length && busy[key] == revision)
			throw new QueryCycle(database.activePath(index, key));
		var verified = key < verifiedAt.length ? verifiedAt[key] : 0;
		var computeValue = compute;
		if (current(database, key)) {
			if (database.checkReuse && computeValue != null && verified != revision) {
				begin(database, key);
				check(database, key, computeValue(database, key));
			}
			return values[key];
		}
		if (computeValue == null)
			throw new InternalError("query " + describe(key) + " is read before its stage computed it");
		begin(database, key);
		return end(database, key, computeValue(database, key));
	}

	/**
	 * Whether `key`'s memo holds at the database's revision: there is one, and nothing its computation read changed after it was
	 * last verified. Brings what it read up to date; records no read. A stage that finds it holds takes `value`.
	 */
	public function current(database:QueryDatabase, key:Int):Bool {
		if (key >= verifiedAt.length)
			return false;
		var revision = database.revision, verified = verifiedAt[key];
		if (verified == revision)
			return true;
		if (verified == 0 || busy[key] == revision)
			return false;
		busy[key] = revision;
		var held = true, through = reads[key];
		if (through != null)
			for (read in through)
				if (database.kindAt(QueryRead.kind(read)).changedAt(database, QueryRead.key(read)) > verified) {
					held = false;
					break;
				}
		busy[key] = 0;
		if (held) {
			verifiedAt[key] = revision;
			usedAt = revision;
		}
		return held;
	}

	/** The value of `key`'s memo, as `current` or `end` left it. */
	public inline function value(key:Int):V
		return values[key];

	/** Starts computing `key` in a stage's run: what is read until `end` (or `check`) is what its computation read. */
	public function begin(database:QueryDatabase, key:Int):Void {
		grow(key);
		var revision = database.revision;
		if (busy[key] == revision)
			throw new QueryCycle(database.activePath(index, key));
		busy[key] = revision;
		database.enter(index, key, true);
	}

	/**
	 * Ends computing `key` (`begin`) with `value`, and returns the value kept: the memo's, when it is `same` as `value` (early
	 * cutoff), which keeps the revision it changed at; else `value`, changed now.
	 */
	public function end(database:QueryDatabase, key:Int, value:V):V {
		var recorded = finish(database, key), revision = database.revision, verified = verifiedAt[key];
		database.countComputation();
		usedAt = revision;
		reads[key] = recorded;
		verifiedAt[key] = revision;
		computedAt[key] = revision;
		if (verified != 0 && same(values[key], value))
			return values[key];
		values[key] = value;
		changes[key] = revision;
		return value;
	}

	/**
	 * `--check-reuse`: ends computing `key` again (`begin`) with `fresh`, which must be `same` as the value of its memo, found to
	 * hold. The memo is left as it was.
	 */
	public function check(database:QueryDatabase, key:Int, fresh:V):Void {
		finish(database, key);
		if (!same(values[key], fresh))
			throw new QueryReuseMismatch(describe(key));
	}

	function finish(database:QueryDatabase, key:Int):Array<Int> {
		if (!database.computing(index, key))
			throw new InternalError("query " + describe(key) + " ends a computation it did not begin");
		busy[key] = 0;
		var recorded = database.leave();
		return recorded == null ? [] : recorded;
	}

	/**
	 * The revision at which `key`'s value last changed, bringing it up to date first. A key being computed or verified is a cycle
	 * its reader's computation meets, and one its stage has not brought up to date (it may be gone) counts as changed: both are
	 * changed now.
	 */
	override public function changedAt(database:QueryDatabase, key:Int):Int {
		var revision = database.revision;
		if (key < busy.length && busy[key] == revision)
			return revision;
		if (current(database, key))
			return changes[key];
		var computeValue = compute;
		if (computeValue == null)
			return revision;
		begin(database, key);
		end(database, key, computeValue(database, key));
		return changes[key];
	}

	override public function sweep(since:Int):Int {
		if (usedAt < since)
			return 0;
		var dropped = 0;
		for (key in 0...verifiedAt.length) {
			var verified = verifiedAt[key];
			if (verified != 0 && verified < since) {
				drop(key);
				dropped++;
			}
		}
		return dropped;
	}

	override function forgetComputedAfter(since:Int):Void
		for (key in 0...verifiedAt.length)
			if (verifiedAt[key] != 0 && computedAt[key] > since)
				drop(key);

	override public function describe(key:Int):String
		return kindName + "(" + (keyName == null ? Std.string(key) : keyName(key)) + ")";

	function drop(key:Int):Void {
		verifiedAt[key] = 0;
		values[key] = null;
		reads[key] = null;
	}

	/** Makes room for `key`, and for half as many keys again, since keys are given densely and in order. */
	function grow(key:Int):Void {
		if (key < verifiedAt.length)
			return;
		var length = key + 1 + (key >> 1);
		values.resize(length);
		verifiedAt.resize(length);
		changes.resize(length);
		computedAt.resize(length);
		reads.resize(length);
		busy.resize(length);
	}
}
