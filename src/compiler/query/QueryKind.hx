package compiler.query;

import compiler.query.QueryErrors.QueryCycle;
import compiler.query.QueryErrors.QueryReuseMismatch;

/**
 * A recorded read: a kind's index and a key in one Int (of a computed kind, the key's slot, `ComputedQueryKind.slotOf`), so that a
 * memo's reads are one array of Ints. A kind registered first has index 0, so its reads are its keys.
 */
class QueryRead {
	public static inline final KEY_BITS = 24;
	public static inline final KEY_MASK = 0xFFFFFF;

	public static inline function of(kind:Int, key:Int):Int
		return (kind << KEY_BITS) | key;

	public static inline function kind(read:Int):Int
		return read >>> KEY_BITS;

	public static inline function key(read:Int):Int
		return read & KEY_MASK;

	/**
	 * Lengthens `column` to `length` with zeros. Not `resize` alone: the Haxe interpreter, which runs the compiler in some tests,
	 * fills what `resize` adds with null.
	 */
	public static function extend(column:Array<Int>, length:Int):Void {
		var from = column.length;
		column.resize(length);
		for (index in from...length)
			column[index] = 0;
	}
}

/**
 * What the database needs of a kind without knowing its value type. A class, not an interface: HashLink calls an interface method
 * by name, a class method through its table.
 */
class QueryKindBase {
	public var kindName(default, null):String;

	/** The kind's position in its database; -1 until registered. */
	public var index(default, null):Int = -1;

	/** The recording frame that last recorded each key (`QueryDatabase.record`), so that a frame records a read once. */
	var recordedBy:Array<Int> = [];

	/**
	 * For a kind that keeps its memos in columns (`ComputedQueryKind`, `IrStageFacts`), by the key a read of it records (`readOf`):
	 * the revision its memo was last verified at (0 for none) and the revision it last changed at. A verification reads a key
	 * verified in its revision here without a call (most reads are of such keys); other kinds leave them empty.
	 */
	var verifiedAt:Array<Int> = [];

	var changes:Array<Int> = [];

	/**
	 * Whether `changes` holds every key's change as it stands, with nothing to verify (a summary between its runs, `QuerySummary`):
	 * a verification reads it without a call too, and a key past it never changed.
	 */
	var settled = false;

	function new(name:String)
		kindName = name;

	@:allow(compiler.query.QueryDatabase)
	function register(index:Int):Void {
		if (this.index >= 0)
			throw new compiler.core.InternalError("query kind " + kindName + " is registered twice");
		if (index > (0xFF:Int))
			throw new compiler.core.InternalError("a query database holds at most 256 kinds");
		this.index = index;
	}

	/**
	 * The revision at which `key`'s value last changed when it is known without a call: it was verified at `revision`, or the kind
	 * is settled; else -1.
	 */
	public inline function changeIfVerified(key:Int, revision:Int):Int
		return settled ? (key < changes.length ? changes[key] : 0) : (key < verifiedAt.length
			&& verifiedAt[key] == revision ? changes[key] : -1);

	/** The key a read of `key` records, which `changeIfVerified` and `changedAt` take; -1 when `key` has no memo. */
	public function readOf(key:Int):Int
		return key;

	/** The revision at which `key`'s value last changed, bringing it up to date first. */
	public function changedAt(database:QueryDatabase, key:Int):Int
		throw new compiler.core.InternalError("query kind " + kindName + " has no changedAt");

	/** Drops the computed memos not used since revision `since`, when the kind was used since; returns how many. Inputs are kept. */
	public function sweep(since:Int):Int
		return 0;

	/** Drops the memos computed after revision `since`: a rollback undid results they may have read (`QueryDatabase.rollBack`). */
	@:allow(compiler.query.QueryDatabase)
	function forgetComputedAfter(since:Int):Void {}

	/**
	 * Drops the values a build put from its own state after revision `since` (`ComputedQueryKind`'s `ofState`): the state a rollback
	 * returns to did not make them, whether or not it undid any result.
	 */
	@:allow(compiler.query.QueryDatabase)
	function forgetStateAfter(since:Int):Void {}

	/**
	 * Marks the results the build in progress wrote as taken by commit `commit` (`QueryDatabase.commit`). A computed memo is a
	 * function of its reads whichever build made it, so only results a stage wrote (`RecordedQueryKind`) take part.
	 */
	@:allow(compiler.query.QueryDatabase)
	function commitWrites(commit:Int):Void {}

	/** Undoes the writes of the commits after `commit` and those no commit took; whether there were any. */
	@:allow(compiler.query.QueryDatabase)
	function undoAfter(commit:Int):Bool
		return false;

	/** Forgets what undoes the commits up to `through`: no rollback returns before it. */
	@:allow(compiler.query.QueryDatabase)
	function forgetUndo(through:Int):Void {}

	public function describe(key:Int):String
		return kindName + "(" + key + ")";

	/** Whether recording frame `stamp` has not recorded `key` yet, marking it recorded. */
	public inline function firstRecord(key:Int, stamp:Int):Bool {
		while (recordedBy.length <= key)
			recordedBy.push(0);
		if (recordedBy[key] == stamp)
			return false;
		recordedBy[key] = stamp;
		return true;
	}

	/** Forgets which frames recorded which keys, for a kind that forgets its keys. */
	function clearRecorded():Void
		recordedBy = [];
}

/** One query's result, with what its computation read and when it last changed. */
class Memo<V> {
	public var value:V;
	public var first:Int;
	public var second:Int;
	public var verifiedAt:Int;
	public var changedAt:Int;

	/** The revision `value` was computed at, which a verification does not move. */
	public var computedAt:Int;

	/** The reads of the computation that made `value` (`QueryRead`), in order. */
	public var reads:Array<Int>;

	public function new(value:V, first:Int, second:Int, revision:Int, reads:Array<Int>) {
		this.value = value;
		this.first = first;
		this.second = second;
		verifiedAt = revision;
		changedAt = revision;
		computedAt = revision;
		this.reads = reads;
	}
}

/**
 * A kind of query: an input, set from outside, or a derived query computed from its key by reading other queries through
 * the database. Keys are dense ids; a kind with richer keys interns them first. Values are owned (ADR 0003 decision 14) and
 * never mutated once returned.
 */
class QueryKind<V> extends QueryKindBase {
	final compute:Null<(QueryDatabase, Int) -> V>;
	final digestValue:(V, Digest) -> Void;
	final sameValue:(V, V) -> Bool;
	final onCycle:Null<Int->V>;
	final keyName:Null<Int->String>;
	final memos:Array<Null<Memo<V>>> = [];
	final active:Array<Bool> = [];
	final scratch = new Digest();

	function new(name:String, compute:Null<(QueryDatabase, Int) -> V>, digestValue:(V, Digest) -> Void,
			sameValue:(V, V) -> Bool, onCycle:Null<Int->V>, keyName:Null<Int->String>) {
		super(name);
		this.compute = compute;
		this.digestValue = digestValue;
		this.sameValue = sameValue;
		this.onCycle = onCycle;
		this.keyName = keyName;
	}

	/** A kind whose values are set from outside: source texts, options, the target profile. */
	public static function input<V>(name:String, digest:(V, Digest) -> Void, same:(V, V) -> Bool,
			?keyName:Int->String):QueryKind<V>
		return new QueryKind<V>(name, null, digest, same, null, keyName);

	/**
	 * A kind computed by `compute`, which reads other queries only through the database. `onCycle` gives the value a read
	 * of this kind takes when it would close a cycle; without it, a cycle is an error.
	 */
	public static function derived<V>(name:String, compute:(QueryDatabase, Int) -> V, digest:(V, Digest) -> Void,
			same:(V, V) -> Bool, ?onCycle:Int->V, ?keyName:Int->String):QueryKind<V>
		return new QueryKind<V>(name, compute, digest, same, onCycle, keyName);

	override public function describe(key:Int):String
		return kindName + "(" + (keyName == null ? Std.string(key) : keyName(key)) + ")";

	/** The value of input `key` as last set, or null when it is not set; records no read. */
	public function peek(key:Int):Null<V> {
		var memo = memoAt(key);
		return memo == null ? null : memo.value;
	}

	@:allow(compiler.query.QueryDatabase)
	function get(database:QueryDatabase, key:Int):V {
		database.record(this, key);
		if (isActive(key)) {
			var recover = onCycle;
			if (recover == null)
				throw new QueryCycle(database.activePath(index, key));
			return recover(key);
		}
		return ensure(database, key).value;
	}

	@:allow(compiler.query.QueryDatabase)
	function set(database:QueryDatabase, key:Int, value:V):Void {
		if (compute != null)
			throw new compiler.core.InternalError("query " + describe(key) + " is derived, not an input");
		var memo = memoAt(key);
		// The same object is the same value: a stage that changes nothing hands back what it was given.
		if (memo != null && memo.value == value)
			return;
		scratch.reset();
		digestValue(value, scratch);
		if (memo != null && memo.first == scratch.first && memo.second == scratch.second) {
			memo.value = value;
			return;
		}
		var revision = database.inputChanged();
		if (memo == null)
			memos[key] = new Memo(value, scratch.first, scratch.second, revision, []);
		else {
			memo.value = value;
			memo.first = scratch.first;
			memo.second = scratch.second;
			memo.verifiedAt = revision;
			memo.changedAt = revision;
		}
	}

	/** Removes input `key`, as a module that leaves the program; a removed input starts a new revision. */
	@:allow(compiler.query.QueryDatabase)
	function remove(database:QueryDatabase, key:Int):Void {
		if (compute != null)
			throw new compiler.core.InternalError("query " + describe(key) + " is derived, not an input");
		if (memoAt(key) == null)
			return;
		memos[key] = null;
		database.inputChanged();
	}

	override public function changedAt(database:QueryDatabase, key:Int):Int {
		// A read of a query on the stack is a cycle the reader's recomputation will meet: count it as changed.
		if (isActive(key))
			return database.revision;
		return ensure(database, key).changedAt;
	}

	override public function sweep(since:Int):Int {
		if (compute == null)
			return 0;
		var dropped = 0;
		for (key in 0...memos.length) {
			var memo = memos[key];
			if (memo != null && memo.verifiedAt < since) {
				memos[key] = null;
				dropped++;
			}
		}
		return dropped;
	}

	override function forgetComputedAfter(since:Int):Void {
		if (compute != null)
			for (key in 0...memos.length) {
				var memo = memos[key];
				if (memo != null && memo.computedAt > since)
					memos[key] = null;
			}
	}

	/** The memo of `key`, current at the database's revision. */
	function ensure(database:QueryDatabase, key:Int):Memo<V> {
		var memo = memoAt(key), revision = database.revision;
		if (memo != null && memo.verifiedAt == revision)
			return memo;
		var computeValue = compute;
		if (computeValue == null) {
			if (memo == null)
				throw new compiler.core.InternalError("input " + describe(key) + " is read before it is set");
			memo.verifiedAt = revision;
			return memo;
		}
		if (memo != null && unchanged(database, key, memo)) {
			memo.verifiedAt = revision;
			if (database.checkReuse)
				checkReused(database, key, memo, computeValue);
			return memo;
		}
		return recompute(database, key, memo, computeValue);
	}

	/** Whether nothing `memo`'s computation read has changed since it was last verified. */
	function unchanged(database:QueryDatabase, key:Int, memo:Memo<V>):Bool {
		var reads = memo.reads, result = true;
		begin(database, key, false);
		try {
			for (read in reads)
				if (database.kindAt(QueryRead.kind(read)).changedAt(database, QueryRead.key(read)) > memo.verifiedAt) {
					result = false;
					break;
				}
		} catch (error:haxe.Exception) {
			end(database, key);
			throw error;
		}
		end(database, key);
		return result;
	}

	function recompute(database:QueryDatabase, key:Int, memo:Null<Memo<V>>,
			computeValue:(QueryDatabase, Int) -> V):Memo<V> {
		begin(database, key, true);
		var value;
		try
			value = computeValue(database, key)
		catch (error:haxe.Exception) {
			end(database, key);
			throw error;
		}
		var reads = end(database, key);
		database.countComputation();
		scratch.reset();
		digestValue(value, scratch);
		var revision = database.revision;
		if (memo == null) {
			var made = new Memo(value, scratch.first, scratch.second, revision, reads);
			memos[key] = made;
			return made;
		}
		memo.reads = reads;
		memo.verifiedAt = revision;
		memo.computedAt = revision;
		// Early cutoff: an equal value keeps the old one and its revision, so readers verify without recomputing.
		if (memo.first != scratch.first || memo.second != scratch.second) {
			memo.value = value;
			memo.first = scratch.first;
			memo.second = scratch.second;
			memo.changedAt = revision;
		}
		return memo;
	}

	function checkReused(database:QueryDatabase, key:Int, memo:Memo<V>, computeValue:(QueryDatabase, Int) -> V):Void {
		begin(database, key, true);
		var fresh;
		try
			fresh = computeValue(database, key)
		catch (error:haxe.Exception) {
			end(database, key);
			throw error;
		}
		end(database, key);
		if (!sameValue(memo.value, fresh))
			throw new QueryReuseMismatch(describe(key));
	}

	/** Puts `key` on the stack; a computation records its reads, a verification records none. */
	function begin(database:QueryDatabase, key:Int, recording:Bool):Void {
		while (active.length <= key)
			active.push(false);
		active[key] = true;
		database.enter(index, key, recording);
	}

	function end(database:QueryDatabase, key:Int):Null<Array<Int>> {
		active[key] = false;
		return database.leaveWithReads();
	}

	inline function isActive(key:Int):Bool
		return key < active.length && active[key];

	inline function memoAt(key:Int):Null<Memo<V>>
		return key < memos.length ? memos[key] : null;
}
