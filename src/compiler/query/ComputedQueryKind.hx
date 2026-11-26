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
 * The memos are columns by key and their reads one pool of Ints, so verifying a key whose reads did not change reads a few Ints
 * and allocates nothing: no frame, no handler, no element of an array of arrays (which HashLink casts on each read), and no call
 * for a read of a key verified in the revision (`QueryKindBase.changeIfVerified`); computing one allocates nothing of the
 * engine's either, as its reads go from the database's frame into the pool. A computation that throws ends the build: the next
 * build drops the frames it left (`QueryDatabase.newRevision`), and the marks of the keys it was busy with are of the revision it
 * ended in.
 *
 * `@:generic`, so each value type has a kind of its own: an erased one reads its values through the any-array accessor and casts
 * them at the caller, calls `same` through an adapter that casts both arguments, and compares two values dynamically.
 */
@:generic
class ComputedQueryKind<V> extends QueryKindBase {
	final same:(V, V) -> Bool;
	final compute:Null<(QueryDatabase, Int) -> V>;
	final keyName:Null<Int->String>;

	// The memos, by key, besides `verifiedAt` and `changes`: the value, the revision it was computed at, and where in `pool` what
	// its computation read (`QueryRead`) starts, and how many reads.
	var values:Array<V> = [];
	var computedAt:Array<Int> = [];
	var readStart:Array<Int> = [];
	var readCount:Array<Int> = [];

	/** The memos' reads, each memo's in one run; a run a memo no longer has is garbage until `compact`. */
	var pool:Array<Int> = [];

	var garbage = 0;

	/** How many verifications of this kind are under way: the pool is compacted only when none is, as they index it. */
	var verifying = 0;

	/** By key, the revision in which it is being computed or verified: a read that comes back to it is a cycle. */
	var busy:Array<Int> = [];

	/** The last revision a memo was verified or computed at: a sweep leaves a kind the build did not use alone. */
	var usedAt = 0;

	/** Whether a key gained a memo since the last sweep: a kind that gained none holds no more memos than the sweep left. */
	var grown = false;

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
		var verifiedAt = this.verifiedAt;
		if (key >= verifiedAt.length)
			return false;
		var revision = database.revision, verified = verifiedAt[key];
		if (verified == revision)
			return true;
		if (verified == 0 || busy[key] == revision)
			return false;
		// The key is marked busy (a read that comes back to it is a cycle) and the pool kept in place only once a read needs a
		// call, which may verify or compute other keys: a read answered inline reaches nothing.
		var held = true,
			called = false,
			kinds = database.kinds,
			pool = this.pool,
			index = readStart[key],
			last = index + readCount[key];
		while (index < last) {
			var read = pool[index++], kind = kinds[QueryRead.kind(read)], target = QueryRead.key(read);
			var change = kind.changeIfVerified(target, revision);
			if (change < 0) {
				if (!called) {
					called = true;
					busy[key] = revision;
					verifying++;
				}
				change = kind.changedAt(database, target);
			}
			if (change > verified) {
				held = false;
				break;
			}
		}
		if (called) {
			verifying--;
			busy[key] = 0;
		}
		if (held) {
			verifiedAt[key] = revision;
			usedAt = revision;
		}
		return held;
	}

	/** The value of `key`'s memo, as `current` or `end` left it. */
	public inline function value(key:Int):V
		return values[key];

	/** The value of `key`'s memo whether or not it holds, or null when it has none; brings nothing up to date. */
	public function kept(key:Int):Null<V>
		return key < verifiedAt.length && verifiedAt[key] != 0 ? values[key] : null;

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
	public inline function end(database:QueryDatabase, key:Int, value:V):V
		return ended(database, key, value, true);

	/**
	 * Ends computing `key` (`begin`) with `value`, changed now without comparing it with the memo's: a stage whose input for `key`
	 * is another function than its memo was made from, whose value is then all but never the same, keeps the comparison's cost.
	 */
	public inline function endChanged(database:QueryDatabase, key:Int, value:V):V
		return ended(database, key, value, false);

	function ended(database:QueryDatabase, key:Int, value:V, compare:Bool):V {
		var revision = database.revision, verified = verifiedAt[key];
		finish(database, key, true);
		database.countComputation();
		usedAt = revision;
		verifiedAt[key] = revision;
		computedAt[key] = revision;
		if (verified != 0 && (values[key] == value || compare && same(values[key], value)))
			return values[key];
		if (verified == 0)
			grown = true;
		values[key] = value;
		changes[key] = revision;
		return value;
	}

	/**
	 * Gives `key` the value its stage made of what the stage was given, reading nothing through the database (the IR the generator
	 * made of a typed function, an object of the typed program), and returns the value kept: the memo's when it is `same` (early
	 * cutoff), else `value`, changed now. Such a key holds until its stage puts it again, which it does in every build before
	 * anything reads it. A key read in this revision changes in a revision of its own, so what read the old value does not hold over
	 * the new one. A stage puts the same object again most of the time, which is found without calling `same`.
	 */
	public function put(database:QueryDatabase, key:Int, value:V):V {
		var revision = database.revision, verified = key < verifiedAt.length ? verifiedAt[key] : 0;
		usedAt = revision;
		if (verified != 0 && (values[key] == value || same(values[key], value))) {
			verifiedAt[key] = revision;
			return values[key];
		}
		grow(key);
		if (verified == revision)
			revision = database.advance();
		else if (verified == 0)
			grown = true;
		garbage += readCount[key];
		readCount[key] = 0;
		values[key] = value;
		verifiedAt[key] = revision;
		computedAt[key] = revision;
		changes[key] = revision;
		usedAt = revision;
		return value;
	}

	/** Drops every memo and the columns, for a compile that keeps no session: their values would stay alive. */
	public function clear():Void {
		values = [];
		verifiedAt = [];
		changes = [];
		computedAt = [];
		readStart = [];
		readCount = [];
		busy = [];
		pool = [];
		garbage = 0;
		grown = false;
		clearRecorded();
	}

	/**
	 * `--check-reuse`: ends computing `key` again (`begin`) with `fresh`, which must be `same` as the value of its memo, found to
	 * hold. The memo is left as it was.
	 */
	public function check(database:QueryDatabase, key:Int, fresh:V):Void {
		finish(database, key, false);
		if (!same(values[key], fresh))
			throw new QueryReuseMismatch(describe(key));
	}

	/** Ends computing `key` again (`begin`) without keeping anything: a check that compares the value itself. */
	public function cancel(database:QueryDatabase, key:Int):Void
		finish(database, key, false);

	/** Ends the frame `begin` started for `key`, keeping what it read as the memo's reads when `keep`. */
	function finish(database:QueryDatabase, key:Int, keep:Bool):Void {
		if (!database.computing(index, key))
			throw new InternalError("query " + describe(key) + " ends a computation it did not begin");
		busy[key] = 0;
		if (keep)
			keepReads(key, verifiedAt[key] != 0, database.reads, database.topReads());
		database.leave();
	}

	/**
	 * The revision at which `key`'s value last changed, bringing it up to date first. A key being computed or verified is a cycle
	 * its reader's computation meets, and one its stage has not brought up to date (it may be gone) counts as changed: both are
	 * changed now.
	 */
	override public function changedAt(database:QueryDatabase, key:Int):Int {
		var revision = database.revision;
		if (key >= verifiedAt.length)
			return compute == null ? revision : computedChange(database, key);
		// Most reads are of a key its stage brought up to date in this revision.
		if (verifiedAt[key] == revision)
			return changes[key];
		if (busy[key] == revision)
			return revision;
		if (current(database, key))
			return changes[key];
		return compute == null ? revision : computedChange(database, key);
	}

	function computedChange(database:QueryDatabase, key:Int):Int {
		var computeValue = compute;
		if (computeValue == null)
			return database.revision;
		begin(database, key);
		end(database, key, computeValue(database, key));
		return changes[key];
	}

	override public function sweep(since:Int):Int {
		if (usedAt < since || !grown)
			return 0;
		grown = false;
		var dropped = 0;
		for (key in 0...verifiedAt.length) {
			var verified = verifiedAt[key];
			if (verified != 0 && verified < since) {
				drop(key);
				dropped++;
			}
		}
		if (garbage > pool.length >> 1)
			compact();
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
		garbage += readCount[key];
		readCount[key] = 0;
	}

	/** Puts `reads` from `from` on in the pool as `key`'s: in place of its old ones when they fit (`had`), else at the end. */
	function keepReads(key:Int, had:Bool, reads:Array<Int>, from:Int):Void {
		var count = reads.length - from, start = readStart[key], pool = this.pool;
		if (had && count <= readCount[key])
			garbage += readCount[key] - count;
		else {
			if (had)
				garbage += readCount[key];
			if (verifying == 0 && garbage > (pool.length >> 1) + 4096)
				compact();
			pool = this.pool;
			start = pool.length;
			pool.resize(start + count);
		}
		for (index in 0...count)
			pool[start + index] = reads[from + index];
		readStart[key] = start;
		readCount[key] = count;
	}

	/** Copies the memos' reads into a pool of their own, without the garbage. */
	function compact():Void {
		var kept:Array<Int> = [];
		for (key in 0...verifiedAt.length)
			if (verifiedAt[key] != 0) {
				var start = readStart[key], count = readCount[key];
				readStart[key] = kept.length;
				for (index in start...start + count)
					kept.push(pool[index]);
			}
		pool = kept;
		garbage = 0;
	}

	/** Makes room for `key`, and for half as many keys again, since keys are given densely and in order. */
	function grow(key:Int):Void {
		if (key < verifiedAt.length)
			return;
		var length = key + 1 + (key >> 1);
		values.resize(length);
		QueryRead.extend(verifiedAt, length);
		QueryRead.extend(changes, length);
		QueryRead.extend(computedAt, length);
		QueryRead.extend(readStart, length);
		QueryRead.extend(readCount, length);
		QueryRead.extend(busy, length);
	}
}
