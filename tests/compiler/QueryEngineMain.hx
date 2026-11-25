import compiler.query.Digest;
import compiler.query.QueryDatabase;
import compiler.query.QueryErrors.QueryCycle;
import compiler.query.QueryErrors.QueryReuseMismatch;
import compiler.query.QueryKind;
import compiler.query.QueryKind.QueryRead;
import compiler.query.RecordedQueryKind;

/** Results a test stage computes itself: each node's own change, its reads, and which reads see only a part (`partOf`). */
class TestRecorded extends RecordedQueryKind {
	public final own:Array<Int> = [];
	public final reads:Array<Null<Array<Int>>> = [];

	/** For a read of a node by another that sees only a part of it, that part's change, by target; -1 for all of it. */
	public final partOf:Array<Int> = [];

	public function new(database:QueryDatabase) {
		super("recorded", database);
		database.register(this);
	}

	public function node(change:Int, ?through:Array<Int>):Int {
		own.push(change);
		reads.push(through);
		partOf.push(-1);
		return own.length - 1;
	}

	override function ownChange(key:Int):Int
		return own[key];

	override function readsOf(key:Int):Null<Array<Int>>
		return reads[key];

	override function partialChange(source:Int, target:Int):Int
		return partOf[target];
}

/** The query engine on synthetic queries: reuse without computing, early cutoff, read order, cycles, sweep, check mode. */
class QueryEngineMain {
	static function expect(value:Bool, message:String):Void
		if (!value)
			throw message;

	static function digestInt(value:Int, digest:Digest):Void
		digest.int(value);

	static function sameInt(left:Int, right:Int):Bool
		return left == right;

	static var hidden = 0;

	static function main():Void {
		var database = new QueryDatabase();
		var source = database.register(QueryKind.input("source", digestInt, sameInt));
		var calls = new Map<String, Int>();
		function count(name:String):Void
			calls.set(name, (calls.get(name) ?? 0) + 1);
		function callsOf(name:String):Int
			return calls.get(name) ?? 0;
		// magnitude(k) = |source(k)|; total = magnitude(0) + magnitude(1); flag(k) = source(k) > 100 ? magnitude(k) : 0
		var magnitude = database.register(QueryKind.derived("magnitude", function(db, key) {
			count("magnitude");
			var value = db.get(source, key);
			return value < 0 ? -value : value;
		}, digestInt, sameInt));
		var total = database.register(QueryKind.derived("total", function(db, _) {
			count("total");
			return db.get(magnitude, 0) + db.get(magnitude, 1);
		}, digestInt, sameInt));

		database.set(source, 0, 2);
		database.set(source, 1, 3);
		expect(database.get(total, 0) == 5, "first total");
		expect(callsOf("total") == 1 && callsOf("magnitude") == 2, "computed once each");

		expect(database.get(total, 0) == 5 && callsOf("total") == 1, "same revision: reused");

		var before = database.revision;
		database.set(source, 1, 3);
		expect(database.revision == before, "setting an equal input starts no revision");

		database.set(source, 1, 4);
		expect(database.get(total, 0) == 6, "an input change recomputes its readers");
		expect(callsOf("magnitude") == 3 && callsOf("total") == 2, "only the changed magnitude and the total");

		database.set(source, 0, -2);
		expect(database.get(total, 0) == 6, "same magnitude");
		expect(callsOf("magnitude") == 4 && callsOf("total") == 2, "early cutoff: an equal magnitude reuses the total");

		// A kind digested by its computation: free to digest, but a recomputed value always counts as changed.
		var computedMagnitude = database.register(QueryKind.computed("computed-magnitude", function(db, key) {
			count("computed-magnitude");
			var value = db.get(source, key);
			return value < 0 ? -value : value;
		}, sameInt));
		var computedReader = database.register(QueryKind.derived("computed-reader", function(db, key) {
			count("computed-reader");
			return db.get(computedMagnitude, key) + 1;
		}, digestInt, sameInt));
		database.set(source, 4, 3);
		expect(database.get(computedReader, 4) == 4, "a reader of a computed digest");
		database.set(source, 5, 1);
		expect(database.get(computedReader, 4) == 4 && callsOf("computed-reader") == 1, "unrelated change: reused");
		database.set(source, 4, -3);
		expect(database.get(computedReader, 4) == 4, "same magnitude");
		expect(callsOf("computed-magnitude") == 2 && callsOf("computed-reader") == 2,
			"no early cutoff through a computed digest: its reader is recomputed");

		// Reads are verified in order: a guard that changes stops verification before the reads behind it.
		var guarded = database.register(QueryKind.derived("guarded", function(db, _) {
			count("guarded");
			return db.get(source, 2) > 0 ? db.get(magnitude, 3) : 0;
		}, digestInt, sameInt));
		database.set(source, 2, 1);
		database.set(source, 3, 7);
		expect(database.get(guarded, 0) == 7, "guarded reads magnitude(3)");
		database.set(source, 2, 0);
		database.set(source, 3, 8);
		var magnitudes = callsOf("magnitude");
		expect(database.get(guarded, 0) == 0, "guard off");
		expect(callsOf("magnitude") == magnitudes, "magnitude(3) is never brought up to date once the guard changed");

		// Cycles: an error without a recovery value, the recovery value with one.
		var loop:Null<QueryKind<Int>> = null;
		loop = database.register(QueryKind.derived("loop", function(db, key) {
			var self = loop;
			return self == null ? 0 : db.get(self, 1 - key) + 1;
		}, digestInt, sameInt, null, function(key) return "k" + key));
		var cycle:Null<QueryCycle> = null;
		try
			database.get(loop, 0)
		catch (error:QueryCycle)
			cycle = error;
		expect(cycle != null && cycle.path.join(" ") == "loop(k0) loop(k1) loop(k0)", "a cycle names its path");
		var recovering:Null<QueryKind<Int>> = null;
		recovering = database.register(QueryKind.derived("recovering", function(db, key) {
			var self = recovering;
			return self == null ? 0 : db.get(self, 1 - key) + 1;
		}, digestInt, sameInt, function(_) return 100));
		expect(database.get(recovering, 0) == 102, "a read closing a cycle takes the kind's recovery value");

		// Sweep drops what the last revision did not use.
		database.set(source, 0, 5);
		database.get(total, 0);
		expect(database.sweep() > 0, "unused results are dropped");
		var computations = database.computations;
		expect(database.get(total, 0) == 9 && database.computations == computations, "used results are kept");

		// Check mode catches a query that reads something it did not record.
		var checked = new QueryDatabase(true);
		var input = checked.register(QueryKind.input("input", digestInt, sameInt));
		var leaky = checked.register(QueryKind.derived("leaky", function(db, _) return db.get(input, 0) + hidden,
			digestInt,
			sameInt));
		checked.set(input, 0, 1);
		expect(checked.get(leaky, 0) == 1, "leaky first");
		var other = checked.register(QueryKind.input("other", digestInt, sameInt));
		checked.set(other, 0, 1);
		expect(checked.get(leaky, 0) == 1, "reused and checked");
		hidden = 1;
		checked.set(other, 0, 2);
		var mismatch:Null<QueryReuseMismatch> = null;
		try
			checked.get(leaky, 0)
		catch (error:QueryReuseMismatch)
			mismatch = error;
		expect(mismatch != null && mismatch.query == "leaky(0)",
			"check mode names the query that read unrecorded state");

		recordedResults();
		stageFrames();
		inputRevisions();

		Sys.println("PASS: query engine reuses, cuts off early, digests by computation, verifies reads in order, reports cycles, sweeps, checks reuse, "
			+ "verifies recorded results through components, records a stage's reads in frames, and tells input revisions from build revisions");
	}

	/** Results a stage computes itself change when they or anything they read did, transitively; a component changes as one. */
	static function recordedResults():Void {
		var database = new QueryDatabase();
		var recorded = new TestRecorded(database);
		var outside = database.register(QueryKind.input("outside", digestInt, sameInt));
		database.set(outside, 0, 1);
		var outsideRead = QueryRead.of(outside.index, 0);
		var start = database.newRevision();
		// a reads b; b and c read each other; c reads d; e is read by a only in part; f reads the outside input.
		var d = recorded.node(start), e = recorded.node(start);
		var b = recorded.node(start), c = recorded.node(start);
		recorded.reads[b] = [QueryRead.of(recorded.index, c)];
		recorded.reads[c] = [QueryRead.of(recorded.index, b), QueryRead.of(recorded.index, d)];
		var a = recorded.node(start, [QueryRead.of(recorded.index, b), QueryRead.of(recorded.index, e)]);
		var f = recorded.node(start, [outsideRead]);
		expect(recorded.latestChange(a) == start, "nothing changed after the start");
		expect(recorded.currentSince([QueryRead.of(recorded.index, a)], start), "a is current");

		var later = database.newRevision();
		recorded.own[d] = later;
		expect(recorded.latestChange(c) == later && recorded.latestChange(b) == later, "a component changes as one");
		expect(recorded.latestChange(a) == later, "through the component");
		expect(!recorded.currentSince([QueryRead.of(recorded.index, a)], start), "a is no longer current");

		var partial = database.newRevision();
		recorded.own[d] = start;
		recorded.own[e] = partial;
		recorded.partOf[e] = start;
		expect(recorded.latestChange(e) == partial, "e itself changed");
		expect(recorded.latestChange(a) == start, "a reads only the part of e that did not change");
		recorded.partOf[e] = partial;
		expect(recorded.latestChange(a) == start, "memoized for the revision");
		database.newRevision();
		expect(recorded.latestChange(a) == partial, "a new revision walks again");

		expect(recorded.latestChange(f) == start, "an input read before the start");
		database.set(outside, 0, 2);
		expect(recorded.latestChange(f) == database.revision, "a read of another kind changes with it");
	}

	/** A stage's frames record each read once, nest, and leave the frame below them recording each read once too. */
	static function stageFrames():Void {
		var database = new QueryDatabase();
		var recorded = new TestRecorded(database);
		for (_ in 0...4)
			recorded.node(0);
		expect(!database.recording, "nothing records outside a frame");
		database.record(recorded, 0);
		database.beginRecording();
		database.record(recorded, 1);
		database.record(recorded, 0);
		database.record(recorded, 1);
		database.beginRecording();
		database.record(recorded, 1);
		database.record(recorded, 2);
		var inner = database.endRecording();
		expect(inner.join(",") == [QueryRead.of(recorded.index, 1), QueryRead.of(recorded.index, 2)].join(","),
			"the inner frame records its own reads");
		database.record(recorded, 1);
		database.record(recorded, 3);
		var outer = database.endRecording();
		expect(outer.join(",") == [1, 0, 3].map(key -> QueryRead.of(recorded.index, key)).join(","),
			"each read once, in order, also after an inner frame");
		var thrown = false;
		try
			database.endRecording()
		catch (_:compiler.core.InternalError)
			thrown = true;
		expect(thrown, "ending a frame that was not begun is an error");
		database.beginRecording();
		database.record(recorded, 0);
		database.newRevision();
		expect(!database.recording && database.depth == 0, "a new build drops the frames a stopped one left open");
	}

	/** Inputs advance the input revision; a build's own revision does not, so a result kept whole is current across builds. */
	static function inputRevisions():Void {
		var database = new QueryDatabase();
		var source = database.register(QueryKind.input("source", digestInt, sameInt));
		database.set(source, 0, 1);
		var inputs = database.inputRevision;
		database.newRevision();
		expect(database.inputRevision == inputs && database.revision > inputs, "a build's revision is no input change");
		database.set(source, 0, 1);
		expect(database.inputRevision == inputs, "an equal input changes nothing");
		database.remove(source, 1);
		expect(database.inputRevision == inputs, "removing an input that is not set changes nothing");
		database.remove(source, 0);
		expect(database.inputRevision > inputs && source.peek(0) == null, "removing one is a change");
	}
}
