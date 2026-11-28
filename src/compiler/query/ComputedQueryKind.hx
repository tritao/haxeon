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
 * The memos are columns by slot: a key's place in the kind, given the first time the key is asked for (`slotFor`) and given again
 * once its memo is dropped, so the columns are as long as the kind holds keys, whatever the numbers of the keys. Only the slot of
 * each key is by key. A read of the kind is of a slot (`QueryRead`), so a verification reads the change of a key verified in the
 * revision without a call (`QueryKindBase.changeIfVerified`), and a stage that holds a key looks its slot up once.
 *
 * Verifying a key whose reads did not change reads a few Ints and allocates nothing: no frame, no handler, no element of an array
 * of arrays (which HashLink casts on each read); computing one allocates nothing of the engine's either, as its reads go from the
 * database's frame into one pool of Ints. A computation that throws ends the build: the next build drops the frames it left
 * (`QueryDatabase.newRevision`).
 *
 * `@:generic`, so each value type has a kind of its own: an erased one reads its values through the any-array accessor and casts
 * them at the caller, calls `same` through an adapter that casts both arguments, and compares two values dynamically.
 */
@:generic
class ComputedQueryKind<V> extends QueryKindBase {
	final same:(V, V) -> Bool;
	final compute:Null<(QueryDatabase, Int) -> V>;
	final keyName:Null<Int->String>;

	/**
	 * Whether the values describe the state a build is made from (a module's declaration keys, the names every module sees), put by
	 * the stage from that state: a rollback to a commit before a value was put drops it, so the kind holds what the state it returns to
	 * held (`forgetStateAfter`).
	 */
	final ofState:Bool;

	/** By key, its slot plus one; 0 for a key without one. */
	var slots:Array<Int> = [];

	/**
	 * By slot, its key, -1 for a slot given back (`drop`); how many slots were given, and the slots given back, which the next new
	 * keys take. The columns by slot are as long as `reserve` or the slots given asked for: a stage reserves what it runs on.
	 */
	var keys:Array<Int> = [];

	var given = 0;
	var free:Array<Int> = [];

	// The memos, by slot, besides `verifiedAt` and `changes`: the value, the revision it was computed at, and where in `pool` what
	// its computation read starts (0 for nothing).
	var values:Array<V> = [];
	var computedAt:Array<Int> = [];
	var readsAt:Array<Int> = [];

	/**
	 * The memos' reads (`QueryRead`), each memo's in one run after the count of its reads; the run at 0 is empty, the run of every
	 * memo that read nothing. A run a memo no longer has is garbage until `compact`.
	 */
	var pool:Array<Int> = [0];

	var garbage = 0;

	/** How many verifications of this kind are under way: the pool is compacted only when none is, as they index it. */
	var verifying = 0;

	/** The last revision a memo was verified or computed at: a sweep leaves a kind the build did not use alone. */
	var usedAt = 0;

	/** Whether a key gained a memo since the last sweep: a kind that gained none holds no more memos than the sweep left. */
	var grown = false;

	/**
	 * A kind whose values `compute` makes, reading other queries only through the database, or, without it, that a stage computes
	 * in its own run. A cycle is an error.
	 */
	public function new(name:String, same:(V, V) -> Bool, ?compute:(QueryDatabase, Int) -> V, ?keyName:Int->String,
			ofState:Bool = false) {
		super(name);
		this.same = same;
		this.compute = compute;
		this.keyName = keyName;
		this.ofState = ofState;
	}

	/** The slot of `key`, or -1 when it has none. */
	public inline function slotOf(key:Int):Int
		return key < slots.length ? slots[key] - 1 : -1;

	/** The slot of `key`, given now when it has none. */
	public inline function slotFor(key:Int):Int {
		var slot = slotOf(key);
		return slot >= 0 ? slot : giveSlot(key);
	}

	/** How long the columns by slot are: every slot given is below it. */
	public inline function capacity():Int
		return keys.length;

	override public function readOf(key:Int):Int
		return slotOf(key);

	/**
	 * Makes room for `count` slots and for keys below `keyCount`, as a stage that runs on that many functions knows before it asks
	 * for their slots: the columns are then as long as that, where growing as slots are given would leave up to half of them empty.
	 */
	public function reserve(count:Int, keyCount:Int):Void {
		if (keyCount > slots.length)
			QueryRead.extend(slots, keyCount);
		if (count > keys.length)
			grow(count);
	}

	function giveSlot(key:Int):Int {
		if (key >= slots.length)
			QueryRead.extend(slots, key + 1 + (key >> 1));
		var slot;
		if (free.length > 0) {
			slot = free[free.length - 1];
			free.resize(free.length - 1);
		} else {
			slot = given++;
			if (slot >= keys.length)
				grow(slot + 1 + (slot >> 1));
		}
		keys[slot] = key;
		slots[key] = slot + 1;
		return slot;
	}

	function grow(length:Int):Void {
		values.resize(length);
		QueryRead.extend(keys, length);
		QueryRead.extend(verifiedAt, length);
		QueryRead.extend(changes, length);
		QueryRead.extend(computedAt, length);
		QueryRead.extend(readsAt, length);
	}

	/**
	 * The value of `key`, recorded as a read of the query being computed, if any: computed when its memo does not hold. A kind a
	 * stage computes must have computed or verified it in this revision.
	 */
	public function get(database:QueryDatabase, key:Int):V {
		var slot = slotFor(key);
		database.record(this, slot);
		if (database.onStack(index, slot))
			throw new QueryCycle(database.activePath(index, slot));
		var revision = database.revision, verified = verifiedAt[slot], computeValue = compute;
		if (current(database, slot)) {
			if (database.checkReuse && computeValue != null && verified != revision) {
				begin(database, slot);
				check(database, slot, computeValue(database, key));
			}
			return values[slot];
		}
		if (computeValue == null)
			throw new InternalError("query " + describe(slot) + " is read before its stage computed it");
		begin(database, slot);
		return end(database, slot, computeValue(database, key));
	}

	/**
	 * Whether the memo in `slot` (-1 for none) holds at the database's revision: there is one, and nothing its computation read
	 * changed after it was last verified. Brings what it read up to date; records no read. A stage that finds it holds takes
	 * `value`.
	 */
	public function current(database:QueryDatabase, slot:Int):Bool {
		if (slot < 0)
			return false;
		var verifiedAt = this.verifiedAt, revision = database.revision, verified = verifiedAt[slot];
		if (verified == revision)
			return true;
		if (verified == 0 || database.onStack(index, slot))
			return false;
		// The memo is put on the stack (a read that comes back to it is a cycle) and the pool kept in place only once a read needs a
		// call, which may verify or compute other keys: a read answered inline reaches nothing.
		var held = true,
			called = false,
			kinds = database.kinds,
			pool = this.pool,
			position = readsAt[slot],
			last = position + 1 + pool[position];
		position++;
		while (position < last) {
			var read = pool[position++], kind = kinds[QueryRead.kind(read)], target = QueryRead.key(read);
			var change = kind.changeIfVerified(target, revision);
			if (change < 0) {
				if (!called) {
					called = true;
					database.enter(index, slot, false);
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
			database.leave();
		}
		if (held) {
			verifiedAt[slot] = revision;
			usedAt = revision;
		}
		return held;
	}

	/** The revision the memo in `slot` was last verified or computed at, 0 for none. */
	public inline function verifiedIn(slot:Int):Int
		return verifiedAt[slot];

	/** The revision the memo in `slot` was last computed at (`end`, `put`), whether or not its value changed. */
	public inline function computedIn(slot:Int):Int
		return computedAt[slot];

	/** The key whose memo is in `slot`, -1 for a slot given back. */
	public inline function keyOf(slot:Int):Int
		return keys[slot];

	/**
	 * Takes the memo in `slot` as verified at the database's revision without reading what it read: for a stage that knows none of
	 * its reads changed since the memo was last verified (`IrFunctionStages.run`, which visits only the keys whose reads changed).
	 */
	public inline function hold(database:QueryDatabase, slot:Int):Void {
		var revision = database.revision;
		verifiedAt[slot] = revision;
		usedAt = revision;
	}

	/** How many reads the memo in `slot` has, and its read at `position`, in the order they were made (`QueryRead`). */
	public inline function readsMade(slot:Int):Int
		return pool[readsAt[slot]];

	public inline function readMade(slot:Int, position:Int):Int
		return pool[readsAt[slot] + 1 + position];

	/** The value of the memo in `slot`, as `current` or `end` left it. */
	public inline function value(slot:Int):V
		return values[slot];

	/**
	 * Keeps `value` in the memo in `slot` in place of its value, which it equals for every reader (a lowering kept for an equal
	 * function made again, `HlFunctionQueries.lowered`): what the memo read and the revisions it was verified and changed at stay.
	 */
	public inline function replace(slot:Int, value:V):Void
		values[slot] = value;

	/** The value of `key`'s memo whether or not it holds, or null when it has none; brings nothing up to date. */
	public function kept(key:Int):Null<V> {
		var slot = slotOf(key);
		return slot >= 0 && verifiedAt[slot] != 0 ? values[slot] : null;
	}

	/** Starts computing the key in `slot` in a stage's run: what is read until `end` (or `check`) is what its computation read. */
	public function begin(database:QueryDatabase, slot:Int):Void {
		if (database.onStack(index, slot))
			throw new QueryCycle(database.activePath(index, slot));
		database.enter(index, slot, true);
	}

	/**
	 * Ends computing the key in `slot` (`begin`) with `value`, and returns the value kept: the memo's, when it is `same` as `value`
	 * (early cutoff), which keeps the revision it changed at; else `value`, changed now.
	 */
	public inline function end(database:QueryDatabase, slot:Int, value:V):V
		return ended(database, slot, value, true);

	/**
	 * Ends computing the key in `slot` (`begin`) with `value`, changed now without comparing it with the memo's: a stage whose input
	 * for the key is another function than its memo was made from, whose value is then all but never the same, keeps the
	 * comparison's cost.
	 */
	public inline function endChanged(database:QueryDatabase, slot:Int, value:V):V
		return ended(database, slot, value, false);

	function ended(database:QueryDatabase, slot:Int, value:V, compare:Bool):V {
		var revision = database.revision, verified = verifiedAt[slot];
		finish(database, slot, true);
		database.countComputation();
		usedAt = revision;
		verifiedAt[slot] = revision;
		computedAt[slot] = revision;
		if (verified != 0 && (values[slot] == value || compare && same(values[slot], value)))
			return values[slot];
		if (verified == 0)
			grown = true;
		values[slot] = value;
		changes[slot] = revision;
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
		var slot = slotFor(key), revision = database.revision, verified = verifiedAt[slot];
		usedAt = revision;
		if (verified != 0 && (values[slot] == value || same(values[slot], value))) {
			verifiedAt[slot] = revision;
			return values[slot];
		}
		if (verified == revision)
			revision = database.advance();
		else if (verified == 0)
			grown = true;
		forgetReads(slot);
		values[slot] = value;
		verifiedAt[slot] = revision;
		computedAt[slot] = revision;
		changes[slot] = revision;
		usedAt = revision;
		return value;
	}

	/** Drops every memo and the columns, for a compile that keeps no session: their values would stay alive. */
	public function clear():Void {
		slots = [];
		keys = [];
		given = 0;
		free = [];
		values = [];
		verifiedAt = [];
		changes = [];
		computedAt = [];
		readsAt = [];
		pool = [0];
		garbage = 0;
		grown = false;
		clearRecorded();
	}

	/**
	 * `--check-reuse`: ends computing the key in `slot` again (`begin`) with `fresh`, which must be `same` as the value of its memo,
	 * found to hold. The memo is left as it was.
	 */
	public function check(database:QueryDatabase, slot:Int, fresh:V):Void {
		finish(database, slot, false);
		if (!same(values[slot], fresh))
			throw new QueryReuseMismatch(describe(slot));
	}

	/** Ends computing the key in `slot` again (`begin`) without keeping anything: a check that compares the value itself. */
	public function cancel(database:QueryDatabase, slot:Int):Void
		finish(database, slot, false);

	/** Ends the frame `begin` started for `slot`, keeping what it read as the memo's reads when `keep`. */
	function finish(database:QueryDatabase, slot:Int, keep:Bool):Void {
		if (!database.computing(index, slot))
			throw new InternalError("query " + describe(slot) + " ends a computation it did not begin");
		if (keep)
			keepReads(slot, database.reads, database.topReads());
		database.leave();
	}

	/**
	 * The revision at which the value in `slot` last changed, bringing it up to date first. A key being computed or verified is a
	 * cycle its reader's computation meets, and one its stage has not brought up to date (it may be gone) counts as changed: both
	 * are changed now.
	 */
	override public function changedAt(database:QueryDatabase, slot:Int):Int {
		var revision = database.revision;
		if (slot >= given || keys[slot] < 0)
			return revision;
		// Most reads are of a key its stage brought up to date in this revision.
		if (verifiedAt[slot] == revision)
			return changes[slot];
		if (database.onStack(index, slot))
			return revision;
		if (current(database, slot))
			return changes[slot];
		var computeValue = compute;
		if (computeValue == null)
			return revision;
		begin(database, slot);
		end(database, slot, computeValue(database, keys[slot]));
		return changes[slot];
	}

	override public function sweep(since:Int):Int {
		if (usedAt < since || !grown)
			return 0;
		grown = false;
		var dropped = 0;
		for (slot in 0...given) {
			var verified = verifiedAt[slot];
			if (verified != 0 && verified < since) {
				drop(slot);
				dropped++;
			}
		}
		if (garbage > pool.length >> 1)
			compact();
		return dropped;
	}

	override function forgetComputedAfter(since:Int):Void
		for (slot in 0...given)
			if (verifiedAt[slot] != 0 && computedAt[slot] > since)
				drop(slot);

	override function forgetStateAfter(since:Int):Void
		if (ofState)
			forgetComputedAfter(since);

	override public function describe(slot:Int):String {
		if (slot >= given || keys[slot] < 0)
			return kindName + "(a dropped key)";
		var key = keys[slot];
		return kindName + "(" + (keyName == null ? Std.string(key) : keyName(key)) + ")";
	}

	/**
	 * Drops the memo in `slot` and gives the slot back. A memo that read it reads the change of the key the slot is given to next,
	 * made after it was verified: it does not hold.
	 */
	function drop(slot:Int):Void {
		verifiedAt[slot] = 0;
		values[slot] = null;
		forgetReads(slot);
		slots[keys[slot]] = 0;
		keys[slot] = -1;
		free.push(slot);
	}

	inline function forgetReads(slot:Int):Void {
		var at = readsAt[slot];
		if (at != 0) {
			garbage += pool[at] + 1;
			readsAt[slot] = 0;
		}
	}

	/** Puts `reads` from `from` on in the pool as the reads of the memo in `slot`: in place of its old ones when they fit. */
	function keepReads(slot:Int, reads:Array<Int>, from:Int):Void {
		var count = reads.length - from, at = readsAt[slot], pool = this.pool;
		if (count == 0) {
			forgetReads(slot);
			return;
		}
		if (at != 0 && count <= pool[at])
			garbage += pool[at] - count;
		else {
			forgetReads(slot);
			if (verifying == 0 && garbage > (pool.length >> 1) + 4096)
				compact();
			pool = this.pool;
			at = pool.length;
			pool.resize(at + 1 + count);
		}
		pool[at] = count;
		for (index in 0...count)
			pool[at + 1 + index] = reads[from + index];
		readsAt[slot] = at;
	}

	/** Copies the memos' reads into a pool of their own, without the garbage. */
	function compact():Void {
		var kept:Array<Int> = [0];
		for (slot in 0...given) {
			var at = readsAt[slot];
			if (at != 0) {
				readsAt[slot] = kept.length;
				for (index in at...at + 1 + pool[at])
					kept.push(pool[index]);
			}
		}
		pool = kept;
		garbage = 0;
	}
}
