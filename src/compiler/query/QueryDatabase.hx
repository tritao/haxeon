package compiler.query;

import compiler.query.QueryKind.QueryKindBase;
import compiler.query.QueryKind.QueryRead;

/**
 * A session's query results (ADR 0003 decision 1, `docs/design/QUERY_ENGINE.md`). Inputs are set from outside; derived
 * queries are computed on demand, recording every query they read. At a new revision a result is reused when nothing it
 * read has changed, without computing it again; and a recomputed result equal to the old one keeps its revision, so its
 * readers are reused too.
 *
 * A stage that computes outside the database (the typer, which types units in its own order) records what it reads the same
 * way, in a frame of its own (`beginRecording`), and keeps the reads with its result (`RecordedQueryKind`). Those results are
 * written in a transaction: a build that is taken commits them (`commit`), and a state the session returns to rolls back what
 * was written after it (`rollBack`).
 */
class QueryDatabase {
	/** Starts at 1 and advances when an input changes and when a build begins (`newRevision`). */
	public var revision(default, null) = 1;

	/** The revision at which an input last changed: what a whole result reused across builds is current with. */
	public var inputRevision(default, null) = 1;

	/** The revision the build in progress started (`newRevision`): what a build used was verified at it or later (`sweep`). */
	public var buildRevision(default, null) = 1;

	/** Check mode (ADR 0003 decision 10): every reused result is computed again and must be equal. */
	public var checkReuse:Bool;

	/** How many derived results were computed since the database was made; reuses and check mode do not count. */
	public var computations(default, null) = 0;

	/** The last commit (`commit`), which a state taken from a build keeps to return to (`rollBack`). */
	public var lastCommit(default, null) = 0;

	/** The oldest commit `rollBack` can return to (`keepRollbackTo`). */
	var rollbackFloor = 0;

	/** By commit, the revision it was made at: what was computed after it was computed over results a rollback to it undoes. */
	final commitRevisions:Array<Int> = [0];

	final kinds:Array<QueryKindBase> = [];

	/** The queries being computed or verified, innermost last, as (kind index, key) pairs; -1, -1 for a stage's frame. */
	final stack:Array<Int> = [];

	/** The reads of each frame on the stack (`QueryRead`): null for a verification, which records nothing. */
	final frames:Array<Null<Array<Int>>> = [];

	/** Each frame's stamp, with which a frame marks the keys it recorded (`QueryKindBase.firstRecord`). */
	final stamps:Array<Int> = [];

	var lastStamp = 0;

	/** How many reads were recorded since the database was made, and how many when each frame on the stack began. */
	var marks = 0;

	final marksAtEnter:Array<Int> = [];

	public function new(checkReuse = false) {
		this.checkReuse = checkReuse;
	}

	public function register<K:QueryKindBase>(kind:K):K {
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

	/** Removes an input; one that was set starts a new revision. */
	public inline function remove<V>(kind:QueryKind<V>, key:Int):Void
		kind.remove(this, key);

	/**
	 * Starts a revision of its own, for a build: what changes from here on changes after everything recorded before. A build
	 * that stopped on an error left its stage's frames open; they are dropped, with what they read.
	 */
	public function newRevision():Int {
		stack.resize(0);
		frames.resize(0);
		stamps.resize(0);
		marksAtEnter.resize(0);
		buildRevision = ++revision;
		return revision;
	}

	/** Takes the results the build in progress wrote: they stay unless a rollback returns before the commit this returns. */
	public function commit():Int {
		lastCommit++;
		commitRevisions.push(revision);
		for (kind in kinds)
			kind.commitWrites(lastCommit);
		return lastCommit;
	}

	/**
	 * Returns the written results to what commit `commit` left: the commits after it, and the writes of a build no commit took,
	 * are undone. Anything found for the revision was found over the results undone, so a rollback that undid something starts a
	 * revision. A result undone takes back the revision it changed at, older than what was computed over the undone one, so what
	 * was computed after the commit is dropped too: verified against the older revision, it would hold.
	 */
	public function rollBack(commit:Int):Void {
		if (commit < rollbackFloor)
			throw new compiler.core.InternalError("query results cannot return to commit " + commit + ", before "
				+ rollbackFloor);
		var undone = false;
		for (kind in kinds)
			if (kind.undoAfter(commit))
				undone = true;
		if (!undone)
			return;
		revision++;
		var since = commitRevisions[commit];
		for (kind in kinds)
			kind.forgetComputedAfter(since);
	}

	/** Keeps what returns to commit `commit` or a later one (`rollBack`), and forgets what returns before it. */
	public function keepRollbackTo(commit:Int):Void {
		rollbackFloor = commit;
		for (kind in kinds)
			kind.forgetUndo(commit);
	}

	/**
	 * Drops the computed results the build in progress did not use, of the kinds it used: call it once a build has brought up to
	 * date everything it keeps. Returns how many.
	 */
	public function sweep():Int {
		var dropped = 0;
		for (kind in kinds)
			dropped += kind.sweep(buildRevision);
		return dropped;
	}

	/** Starts a frame recording what a stage computing outside the database reads, until the matching `endRecording`. */
	public function beginRecording():Void
		enter(-1, -1, true);

	/** Ends the frame `beginRecording` started last: what it read, in order, each read once. */
	public function endRecording():Array<Int> {
		if (frames.length == 0 || stack[stack.length - 2] != -1)
			throw new compiler.core.InternalError("no stage frame is recording");
		var reads = leave();
		return reads == null ? [] : reads;
	}

	/** Whether a frame records reads: a read now is recorded. */
	public var recording(get, never):Bool;

	inline function get_recording():Bool
		return frames.length > 0 && frames[frames.length - 1] != null;

	/** How many frames are on the stack. */
	public var depth(get, never):Int;

	inline function get_depth():Int
		return frames.length;

	/** A stamp no frame has, for a caller that marks keys itself (`QueryKindBase.firstRecord`), as merging two read lists does. */
	public function newStamp():Int
		return ++lastStamp;

	/** Records that the frame on top read `key` of `kind`, once per frame. */
	public function record(kind:QueryKindBase, key:Int):Void {
		var top = frames.length - 1;
		if (top < 0)
			return;
		var reads = frames[top];
		if (reads != null && kind.firstRecord(key, stamps[top])) {
			if (key > QueryRead.KEY_MASK)
				throw new compiler.core.InternalError("query key " + key + " of " + kind.kindName
					+ " does not fit a read");
			reads.push(QueryRead.of(kind.index, key));
			marks++;
		}
	}

	@:allow(compiler.query)
	function countComputation():Void
		computations++;

	@:allow(compiler.query)
	inline function kindAt(index:Int):QueryKindBase
		return kinds[index];

	@:allow(compiler.query)
	function inputChanged():Int {
		inputRevision = ++revision;
		return revision;
	}

	@:allow(compiler.query)
	function enter(kind:Int, key:Int, recording:Bool):Void {
		stack.push(kind);
		stack.push(key);
		frames.push(recording ? [] : null);
		stamps.push(++lastStamp);
		marksAtEnter.push(marks);
	}

	/**
	 * Pops the top frame, giving its reads. When it or a frame inside it recorded anything, the nearest recording frame below takes
	 * its marks again, which those overwrote.
	 */
	@:allow(compiler.query)
	function leave():Null<Array<Int>> {
		stack.pop();
		stack.pop();
		stamps.pop();
		var reads = frames.pop(), recordedInside = marksAtEnter.pop() != marks;
		if (reads != null && recordedInside) {
			var below = frames.length - 1;
			while (below >= 0 && frames[below] == null)
				below--;
			if (below >= 0) {
				var stamp = stamps[below];
				for (read in frames[below])
					kinds[QueryRead.kind(read)].firstRecord(QueryRead.key(read), stamp);
			}
		}
		return reads;
	}

	/** Whether the frame on top is the computation of (`kind`, `key`). */
	@:allow(compiler.query)
	inline function computing(kind:Int, key:Int):Bool {
		var top = stack.length - 2;
		return top >= 0 && stack[top] == kind && stack[top + 1] == key && frames[frames.length - 1] != null;
	}

	/** The queries from the first time (`kind`, `key`) is on the stack to the top, then (`kind`, `key`) again. */
	@:allow(compiler.query)
	function activePath(kind:Int, key:Int):Array<String> {
		var start = 0;
		while (start < stack.length && !(stack[start] == kind && stack[start + 1] == key))
			start += 2;
		var path = [];
		var index = start;
		while (index < stack.length) {
			if (stack[index] >= 0)
				path.push(kinds[stack[index]].describe(stack[index + 1]));
			index += 2;
		}
		path.push(kinds[kind].describe(key));
		return path;
	}
}
