package compiler.query;

import compiler.query.QueryKind.AnyQueryKind;

/**
 * A session's query results (ADR 0003 decision 1, `docs/design/QUERY_ENGINE.md`). Inputs are set from outside; derived
 * queries are computed on demand, recording every query they read. At a new revision a result is reused when nothing it
 * read has changed, without computing it again; and a recomputed result equal to the old one keeps its revision, so its
 * readers are reused too.
 */
class QueryDatabase {
	/** Starts at 1 and advances when an input changes. */
	public var revision(default, null) = 1;

	/** Check mode (ADR 0003 decision 10): every reused result is computed again and must be equal. */
	public var checkReuse:Bool;

	/** How many derived results were computed since the database was made; reuses and check mode do not count. */
	public var computations(default, null) = 0;

	final kinds:Array<AnyQueryKind> = [];

	/** The queries being computed or verified, innermost last, as (kind index, key) pairs. */
	final stack:Array<Int> = [];

	/** The reads of the queries on the stack: null for a verification, which records nothing. */
	final frames:Array<Null<Array<Int>>> = [];

	public function new(checkReuse = false) {
		this.checkReuse = checkReuse;
	}

	public function register<V>(kind:QueryKind<V>):QueryKind<V> {
		kind.register(kinds.length);
		kinds.push(kind);
		return kind;
	}

	/** The value of `kind` at `key`, recorded as a read of the query being computed, if any. */
	public inline function get<V>(kind:QueryKind<V>, key:Int):V
		return kind.get(this, key);

	/** Sets an input; a value with a different digest starts a new revision. */
	public inline function set<V>(kind:QueryKind<V>, key:Int, value:V):Void
		kind.set(this, key, value);

	/** Drops the derived results not used since the last revision began; returns how many. */
	public function sweep():Int {
		var dropped = 0;
		for (kind in kinds)
			dropped += kind.sweep(revision);
		return dropped;
	}

	@:allow(compiler.query.QueryKind)
	function newRevision():Int
		return ++revision;

	@:allow(compiler.query.QueryKind)
	function countComputation():Void
		computations++;

	@:allow(compiler.query.QueryKind)
	inline function kindAt(index:Int):AnyQueryKind
		return kinds[index];

	@:allow(compiler.query.QueryKind)
	function record(kind:Int, key:Int):Void {
		if (frames.length == 0)
			return;
		var reads = frames[frames.length - 1];
		if (reads != null) {
			reads.push(kind);
			reads.push(key);
		}
	}

	@:allow(compiler.query.QueryKind)
	function enter(kind:Int, key:Int, reads:Null<Array<Int>>):Void {
		stack.push(kind);
		stack.push(key);
		frames.push(reads);
	}

	@:allow(compiler.query.QueryKind)
	function leave():Void {
		stack.pop();
		stack.pop();
		frames.pop();
	}

	/** The queries from the first time (`kind`, `key`) is on the stack to the top, then (`kind`, `key`) again. */
	@:allow(compiler.query.QueryKind)
	function activePath(kind:Int, key:Int):Array<String> {
		var start = 0;
		while (start < stack.length && !(stack[start] == kind && stack[start + 1] == key))
			start += 2;
		var path = [];
		var index = start;
		while (index < stack.length) {
			path.push(kinds[stack[index]].describe(stack[index + 1]));
			index += 2;
		}
		path.push(kinds[kind].describe(key));
		return path;
	}
}
