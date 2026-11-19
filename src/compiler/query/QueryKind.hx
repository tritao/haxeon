package compiler.query;

import compiler.query.QueryErrors.QueryCycle;
import compiler.query.QueryErrors.QueryReuseMismatch;

/** What the database needs of a kind without knowing its value type. */
interface AnyQueryKind {
	var name(default, null):String;

	/** The revision at which `key`'s value last changed, bringing it up to date first. */
	function changedAt(database:QueryDatabase, key:Int):Int;

	/** Drops the memos not verified at `revision`; returns how many. Inputs are kept. */
	function sweep(revision:Int):Int;

	function describe(key:Int):String;
}

/** One query's result, with what its computation read and when it last changed. */
class Memo<V> {
	public var value:V;
	public var first:Int;
	public var second:Int;
	public var verifiedAt:Int;
	public var changedAt:Int;

	/** The reads of the computation that made `value`, as (kind index, key) pairs, in order. */
	public var reads:Array<Int>;

	public function new(value:V, first:Int, second:Int, revision:Int, reads:Array<Int>) {
		this.value = value;
		this.first = first;
		this.second = second;
		verifiedAt = revision;
		changedAt = revision;
		this.reads = reads;
	}
}

/**
 * A kind of query: an input, set from outside, or a derived query computed from its key by reading other queries through
 * the database. Keys are dense ids; a kind with richer keys interns them first. Values are owned (ADR 0003 decision 14) and
 * never mutated once returned.
 */
class QueryKind<V> implements AnyQueryKind {
	public var name(default, null):String;

	/** The kind's position in its database; -1 until registered. */
	public var index(default, null):Int = -1;

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
		this.name = name;
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

	@:allow(compiler.query.QueryDatabase)
	function register(index:Int):Void {
		if (this.index >= 0)
			throw new compiler.core.InternalError("query kind " + name + " is registered twice");
		this.index = index;
	}

	public function describe(key:Int):String
		return name + "(" + (keyName == null ? Std.string(key) : keyName(key)) + ")";

	@:allow(compiler.query.QueryDatabase)
	function get(database:QueryDatabase, key:Int):V {
		database.record(index, key);
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
		if (memo != null && memo.first == scratch.first && memo.second == scratch.second)
			return;
		var revision = database.newRevision();
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

	public function changedAt(database:QueryDatabase, key:Int):Int {
		// A read of a query on the stack is a cycle the reader's recomputation will meet: count it as changed.
		if (isActive(key))
			return database.revision;
		return ensure(database, key).changedAt;
	}

	public function sweep(revision:Int):Int {
		if (compute == null)
			return 0;
		var dropped = 0;
		for (key in 0...memos.length) {
			var memo = memos[key];
			if (memo != null && memo.verifiedAt < revision) {
				memos[key] = null;
				dropped++;
			}
		}
		return dropped;
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
		var reads = memo.reads, index = 0, result = true;
		begin(database, key, null);
		try {
			while (index < reads.length) {
				if (database.kindAt(reads[index]).changedAt(database, reads[index + 1]) > memo.verifiedAt) {
					result = false;
					break;
				}
				index += 2;
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
		var reads:Array<Int> = [];
		var value = run(database, key, reads, computeValue);
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
		var fresh = run(database, key, [], computeValue);
		if (!sameValue(memo.value, fresh))
			throw new QueryReuseMismatch(describe(key));
	}

	function run(database:QueryDatabase, key:Int, reads:Array<Int>, computeValue:(QueryDatabase, Int) -> V):V {
		begin(database, key, reads);
		var value;
		try
			value = computeValue(database, key)
		catch (error:haxe.Exception) {
			end(database, key);
			throw error;
		}
		end(database, key);
		return value;
	}

	function begin(database:QueryDatabase, key:Int, reads:Null<Array<Int>>):Void {
		active[key] = true;
		database.enter(index, key, reads);
	}

	function end(database:QueryDatabase, key:Int):Void {
		active[key] = false;
		database.leave();
	}

	inline function isActive(key:Int):Bool
		return key < active.length && active[key];

	inline function memoAt(key:Int):Null<Memo<V>>
		return key < memos.length ? memos[key] : null;
}
