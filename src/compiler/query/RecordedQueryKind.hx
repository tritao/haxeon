package compiler.query;

import compiler.query.QueryKind.QueryKindBase;
import compiler.query.QueryKind.QueryRead;

/** A result a stage computed outside the database (`RecordedQueryKind`): the revision it was computed at and what it read. */
class RecordedResult {
	/** It is current while nothing it read changed after this revision. */
	public final revision:Int;

	/** What it read (`QueryRead`), in order, each once. */
	public final reads:Array<Int>;

	public function new(revision:Int, reads:Array<Int>) {
		this.revision = revision;
		this.reads = reads;
	}
}

/**
 * A kind whose results a stage computes outside the database, in its own order, and keeps with the reads it recorded
 * (`QueryDatabase.beginRecording`), or that are set from outside with the keys they go through. A result has no digest of its
 * own: it changed when it last changed itself or when anything it read changed, transitively, so its readers get no early
 * cutoff. Results that read each other are one component (Tarjan's algorithm, without recursion, since chains can be long),
 * and every member changed when the latest of them did: such results come from one computation, whose order of reads is the
 * stage's.
 *
 * A build writes its results in a transaction (`write`): the database commits them when the build is taken (`QueryDatabase.commit`),
 * and a build that is not taken leaves them to be undone, as is every commit after a state the session returns to
 * (`QueryDatabase.rollBack`). The results describe what the taken state holds (the typed bodies a unit's reads are of), so they
 * must be that state's, not a rejected build's.
 *
 * A subclass gives each key's own change, its reads (by default its result's) and, for a read that goes through only a part of
 * what it reads (a declaration naming a type reads only the type's kind), that part's change.
 */
class RecordedQueryKind extends QueryKindBase {
	/** The database the kind is registered in, whose revision its walks are memoized for. */
	public final database:QueryDatabase;

	/** The latest change of each key and of what it reads, for the revision in `effectiveIn`. */
	var effective:Array<Int> = [];

	var effectiveIn:Array<Int> = [];

	/** Each key's result as written so far (`write`), committed or not; null for none. */
	var results:Array<Null<RecordedResult>> = [];

	// What undoes each write, oldest first: the commit that took it (`OPEN` while none has), its key and the result it replaced.
	var undoCommits:Array<Int> = [];
	var undoKeys:Array<Int> = [];
	var undoResults:Array<Null<RecordedResult>> = [];

	static inline final OPEN = 0x7FFFFFFF;

	function new(name:String, database:QueryDatabase) {
		super(name);
		this.database = database;
	}

	/** `key`'s result, or null for none. */
	public inline function result(key:Int):Null<RecordedResult>
		return key < results.length ? results[key] : null;

	/** Every key that has a result is below this. */
	public var resultLimit(get, never):Int;

	inline function get_resultLimit():Int
		return results.length;

	/** Sets `key`'s result, or removes it (null), in the transaction of the build in progress. */
	public function write(key:Int, result:Null<RecordedResult>):Void {
		while (results.length <= key)
			results.push(null);
		undoCommits.push(OPEN);
		undoKeys.push(key);
		undoResults.push(results[key]);
		results[key] = result;
	}

	override function commitWrites(commit:Int):Void {
		var index = undoCommits.length - 1;
		while (index >= 0 && undoCommits[index] == OPEN) {
			undoCommits[index] = commit;
			index--;
		}
	}

	override function undoAfter(commit:Int):Bool {
		var index = undoCommits.length;
		while (index > 0 && undoCommits[index - 1] > commit) {
			index--;
			results[undoKeys[index]] = undoResults[index];
		}
		if (index == undoCommits.length)
			return false;
		undoCommits.resize(index);
		undoKeys.resize(index);
		undoResults.resize(index);
		return true;
	}

	override function forgetUndo(through:Int):Void {
		var count = 0;
		while (count < undoCommits.length && undoCommits[count] <= through)
			count++;
		if (count == 0)
			return;
		undoCommits.splice(0, count);
		undoKeys.splice(0, count);
		undoResults.splice(0, count);
	}

	/** The revision at which `key` last changed itself. */
	function ownChange(key:Int):Int
		throw new compiler.core.InternalError("query kind " + kindName + " has no ownChange");

	/** What `key` read (`QueryRead`), or null for nothing: its result's reads. */
	function readsOf(key:Int):Null<Array<Int>> {
		var held = result(key);
		return held == null ? null : held.reads;
	}

	/** The change a read of this kind's `target` by `source` sees when it is less than all of `target`; -1 for all of it. */
	function partialChange(source:Int, target:Int):Int
		return -1;

	override public function changedAt(database:QueryDatabase, key:Int):Int
		return latestChange(key);

	/** Whether nothing `reads` names changed after `since`. */
	public function currentSince(reads:Array<Int>, since:Int):Bool {
		for (read in reads)
			if (readChange(read) > since)
				return false;
		return true;
	}

	/** The latest change of read `read`: of this kind through `latestChange`, of another as that kind gives it. */
	public inline function readChange(read:Int):Int {
		var kind = QueryRead.kind(read);
		return kind == index ? latestChange(QueryRead.key(read)) : database.kindAt(kind)
			.changedAt(database, QueryRead.key(read));
	}

	/** The latest revision at which `key`, or anything it reads, changed. Memoized for the revision. */
	public function latestChange(key:Int):Int {
		var revision = database.revision;
		if (key < effectiveIn.length && effectiveIn[key] == revision)
			return effective[key];
		var reads = readsOf(key);
		if (reads == null) {
			var change = ownChange(key);
			remember(key, change, revision);
			return change;
		}
		walkEpoch++;
		counter = 0;
		enter(key, reads);
		while (path.length > 0) {
			var top = path.length - 1, node = path[top], through = successors[top], position = next[top];
			if (through != null && position < through.length && latest[node] < revision) {
				next[top] = position + 1;
				var read = through[position];
				if (QueryRead.kind(read) != index) {
					var change = database.kindAt(QueryRead.kind(read)).changedAt(database, QueryRead.key(read));
					if (change > latest[node])
						latest[node] = change;
					continue;
				}
				var successor = QueryRead.key(read), part = partialChange(node, successor);
				if (part >= 0) {
					if (part > latest[node])
						latest[node] = part;
					continue;
				}
				if (successor < effectiveIn.length && effectiveIn[successor] == revision) {
					if (effective[successor] > latest[node])
						latest[node] = effective[successor];
				} else if (successor >= visitedIn.length || visitedIn[successor] != walkEpoch)
					enter(successor, readsOf(successor));
				else if (onPath[successor] && order[successor] < lowest[node])
					lowest[node] = order[successor];
				continue;
			}
			path.pop();
			next.pop();
			successors.pop();
			if (lowest[node] == order[node]) {
				// `node` heads a component: every member gets the latest change of all of them.
				var start = members.lastIndexOf(node), change = 0;
				for (index in start...members.length)
					if (latest[members[index]] > change)
						change = latest[members[index]];
				for (index in start...members.length) {
					var member = members[index];
					onPath[member] = false;
					remember(member, change, revision);
				}
				members.resize(start);
			}
			if (path.length > 0) {
				var parent = path[path.length - 1];
				if (lowest[node] < lowest[parent])
					lowest[parent] = lowest[node];
				var change = node < effectiveIn.length
					&& effectiveIn[node] == revision ? effective[node] : latest[node];
				if (change > latest[parent])
					latest[parent] = change;
			}
		}
		return effective[key];
	}

	inline function remember(key:Int, change:Int, revision:Int):Void {
		while (effectiveIn.length <= key) {
			effectiveIn.push(0);
			effective.push(0);
		}
		effective[key] = change;
		effectiveIn[key] = revision;
	}

	/** Puts `node` on the walk's path, with what it reads. */
	function enter(node:Int, reads:Null<Array<Int>>):Void {
		growWalk(node);
		visitedIn[node] = walkEpoch;
		order[node] = counter;
		lowest[node] = counter;
		counter++;
		members.push(node);
		onPath[node] = true;
		latest[node] = ownChange(node);
		path.push(node);
		next.push(0);
		successors.push(reads);
	}

	/** Forgets every key's result and walk state, for a subclass that forgets its keys. */
	function clearKeys():Void {
		clearRecorded();
		results = [];
		undoCommits = [];
		undoKeys = [];
		undoResults = [];
		effective = [];
		effectiveIn = [];
		members = [];
		path = [];
		next = [];
		successors = [];
		visitedIn = [];
		order = [];
		lowest = [];
		latest = [];
		onPath = [];
	}

	// The walk's stacks, kept between walks so that a walk allocates nothing once they have grown.
	var members:Array<Int> = [];
	var path:Array<Int> = [];
	var next:Array<Int> = [];
	var successors:Array<Null<Array<Int>>> = [];
	var counter = 0;

	// The walk's state per key, valid where `visitedIn` holds the walk's number.
	var visitedIn:Array<Int> = [];
	var order:Array<Int> = [];
	var lowest:Array<Int> = [];
	var latest:Array<Int> = [];
	var onPath:Array<Bool> = [];
	var walkEpoch = 0;

	function growWalk(key:Int):Void
		while (visitedIn.length <= key) {
			visitedIn.push(0);
			order.push(0);
			lowest.push(0);
			latest.push(0);
			onPath.push(false);
		}
}
