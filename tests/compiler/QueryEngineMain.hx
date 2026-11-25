import compiler.core.InternalError;
import compiler.query.ComputedQueryKind;
import compiler.query.Digest;
import compiler.query.QueryDatabase;
import compiler.query.QueryErrors.QueryCycle;
import compiler.query.QueryErrors.QueryReuseMismatch;
import compiler.query.QueryKind;
import compiler.query.QueryKind.QueryRead;
import compiler.query.QuerySummary;
import compiler.query.RecordedQueryKind;
import compiler.query.RecordedQueryKind.RecordedResult;

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

/** Results a test stage writes in the database's transactions (`RecordedQueryKind.write`), read through their reads. */
class TestWritten extends RecordedQueryKind {
	public final own:Array<Int> = [];

	public function new(database:QueryDatabase) {
		super("written", database);
		database.register(this);
	}

	override function ownChange(key:Int):Int
		return key < own.length ? own[key] : 0;
}

/** A boxed value: identity tells a value kept by early cutoff from an equal one computed again. */
class Box {
	public final value:Int;

	public function new(value:Int)
		this.value = value;

	public static function same(left:Box, right:Box):Bool
		return left.value == right.value;
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

		// Sweep drops what the build did not use.
		database.newRevision();
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
		transactions();
		computedKinds();
		stageKinds();
		summaries();
		computedSweep();
		computedTransactions();
		putKinds();

		Sys.println("PASS: query engine reuses, cuts off early, verifies reads in order, reports cycles, sweeps, checks reuse, "
			+ "verifies recorded results through components, records a stage's reads in frames, tells input revisions from build revisions, "
			+ "commits and rolls back written results, cuts computed values off by equality on demand and in a stage's run, updates "
			+ "summaries per changed contribution with per-key reads, sweeps the computed memos a build did not use, and drops those "
			+ "computed over results a rollback undid, and keeps what a stage puts by identity or equality");
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

	/**
	 * Written results are seen at once, kept by a commit, undone when a state before it is returned to, and forgotten once no
	 * state can return before them.
	 */
	static function transactions():Void {
		var database = new QueryDatabase();
		var written = new TestWritten(database);
		for (_ in 0...3)
			written.own.push(0);
		var start = database.newRevision();
		written.write(0, new RecordedResult(start, [QueryRead.of(written.index, 1)]));
		expect(written.result(0) != null && written.result(1) == null, "a write is read back before it is committed");
		var first = database.commit();
		expect(first == database.lastCommit && written.result(0) != null, "a commit keeps the writes");

		var later = database.newRevision();
		written.own[1] = later;
		expect(written.latestChange(0) == later, "a result changes with what its reads name");
		written.write(0, null);
		written.write(1, new RecordedResult(later, [QueryRead.of(written.index, 2)]));
		database.rollBack(first);
		expect(written.result(0) != null && written.result(1) == null, "a build not taken is undone");
		expect(database.revision > later, "undoing starts a revision, as what was found for the old one is stale");
		database.rollBack(first);

		database.newRevision();
		written.write(1, new RecordedResult(database.revision, []));
		var second = database.commit();
		written.write(1, null);
		written.write(2, new RecordedResult(database.revision, []));
		written.write(2, new RecordedResult(database.revision, [QueryRead.of(written.index, 0)]));
		var third = database.commit();
		expect(written.result(1) == null && written.result(2).reads.length == 1,
			"the last write of a key is the one kept");
		database.rollBack(second);
		expect(written.result(1) != null && written.result(2) == null,
			"returning to a commit undoes the ones after it");
		expect(third > second, "commits are numbered on");

		database.newRevision();
		written.write(0, null);
		var fourth = database.commit();
		database.keepRollbackTo(fourth);
		var refused = false;
		try
			database.rollBack(second)
		catch (_:compiler.core.InternalError)
			refused = true;
		expect(refused && written.result(0) == null, "a rollback before what is kept is refused");
		database.rollBack(fourth);
		expect(written.result(0) == null && written.result(1) != null, "returning to the kept commit changes nothing");
	}

	static function throwsInternal(action:() -> Void):Bool {
		try
			action()
		catch (_:InternalError)
			return true;
		return false;
	}

	/** Computed on demand: reuse without computing, early cutoff by equality that keeps the old object, recompute on change. */
	static function computedKinds():Void {
		var database = new QueryDatabase();
		var source = database.register(QueryKind.input("source", digestInt, sameInt));
		var magnitudes = 0, readers = 0;
		var magnitude = database.register(new ComputedQueryKind<Box>("magnitude", Box.same, function(db, key) {
			magnitudes++;
			var value = db.get(source, key);
			return new Box(value < 0 ? -value : value);
		}));
		var reader = database.register(new ComputedQueryKind<Box>("reader", Box.same, function(db, key) {
			readers++;
			return new Box(magnitude.get(db, key).value + 1);
		}));
		database.newRevision();
		database.set(source, 0, 3);
		database.set(source, 1, 5);
		var first = reader.get(database, 0);
		expect(first.value == 4 && magnitudes == 1 && readers == 1, "computed once each");
		expect(reader.get(database, 0) == first && readers == 1, "same revision: reused");
		database.set(source, 1, 6);
		expect(reader.get(database, 0) == first && magnitudes == 1 && readers == 1,
			"an unrelated change: verified without computing");
		var kept = magnitude.get(database, 0);
		database.set(source, 0, -3);
		expect(reader.get(database, 0) == first && magnitudes == 2 && readers == 1,
			"early cutoff: an equal magnitude keeps its reader");
		expect(magnitude.get(database, 0) == kept, "and keeps the object it had");
		database.set(source, 0, 7);
		expect(reader.get(database, 0).value == 8 && magnitudes == 3 && readers == 2, "a change recomputes through");
		var digested = database.register(QueryKind.derived("digested", (db, key) -> magnitude.get(db, key).value * 2,
			digestInt, sameInt));
		expect(database.get(digested, 0) == 14, "a kind digested by content reads a computed one");
		database.set(source, 0, -7);
		expect(database.get(digested, 0) == 14 && magnitudes == 4, "and is cut off by its equality");

		var loop:Null<ComputedQueryKind<Box>> = null;
		loop = database.register(new ComputedQueryKind<Box>("loop", Box.same, function(db, key) {
			var self = loop;
			return self == null ? new Box(0) : self.get(db, 1 - key);
		}));
		var cycle:Null<QueryCycle> = null;
		try
			loop.get(database, 0)
		catch (error:QueryCycle)
			cycle = error;
		expect(cycle != null && cycle.path.join(" ") == "loop(0) loop(1) loop(0)",
			"a cycle is an error naming its path");

		// Check mode computes what held again: a computation that read state it did not record differs.
		var checked = new QueryDatabase(true);
		var input = checked.register(QueryKind.input("input", digestInt, sameInt));
		var leaky = checked.register(new ComputedQueryKind<Box>("leaky", Box.same,
			(db, key) -> new Box(db.get(input, key) + hidden)));
		checked.set(input, 0, 1);
		hidden = 0;
		expect(leaky.get(checked, 0).value == 1, "leaky first");
		checked.set(input, 1, 1);
		expect(leaky.get(checked, 0).value == 1, "held and checked");
		hidden = 2;
		checked.set(input, 1, 2);
		var mismatch:Null<QueryReuseMismatch> = null;
		try
			leaky.get(checked, 0)
		catch (error:QueryReuseMismatch)
			mismatch = error;
		expect(mismatch != null && mismatch.query == "leaky(0)",
			"check mode names the computed query that read unrecorded state");
		hidden = 0;
	}

	/**
	 * Computed in a stage's own run, as a pass rewrites functions: a rewrite holds while its input does, an equal one computed again
	 * keeps the object so the next stage holds, and one its stage has not brought up to date counts as changed.
	 */
	static function stageKinds():Void {
		var database = new QueryDatabase();
		var functions = database.register(QueryKind.input("function", digestInt, sameInt));
		var first = database.register(new ComputedQueryKind<Box>("first", Box.same));
		var second = database.register(new ComputedQueryKind<Box>("second", Box.same));
		var firstRuns = 0, secondRuns = 0;
		function absolute(db:QueryDatabase, key:Int):Box {
			firstRuns++;
			var value = db.get(functions, key);
			return new Box((value < 0 ? -value : value) + hidden);
		}
		function successor(db:QueryDatabase, key:Int):Box {
			secondRuns++;
			return new Box(first.get(db, key).value + 1);
		}
		function stage(kind:ComputedQueryKind<Box>, count:Int, transform:(QueryDatabase, Int) -> Box):Array<Box>
			return [for (key in 0...count)
				if (kind.current(database, key)) {
					if (database.checkReuse) {
						kind.begin(database, key);
						kind.check(database, key, transform(database, key));
					}
					kind.value(key);
				} else {
				kind.begin(database, key);
				kind.end(database, key, transform(database, key));
			}];
		function build(values:Array<Int>):Array<Box> {
			database.newRevision();
			for (key in 0...values.length)
				database.set(functions, key, values[key]);
			stage(first, values.length, absolute);
			return stage(second, values.length, successor);
		}
		var output = build([1, 2, 3]);
		expect(output.map(box -> box.value).join(",") == "2,3,4" && firstRuns == 3 && secondRuns == 3,
			"a first run computes all");
		var again = build([1, 2, 3]);
		expect(firstRuns == 3 && secondRuns == 3 && again[1] == output[1], "an unchanged build computes nothing");
		var cut = build([1, -2, 3]);
		expect(firstRuns == 4 && secondRuns == 3 && cut[1] == output[1],
			"an equal rewrite keeps the next stage's memo");
		var changed = build([1, -2, 4]);
		expect(firstRuns == 5 && secondRuns == 4 && changed[2].value == 5 && changed[0] == output[0],
			"a change recomputes only its own function");

		database.newRevision();
		database.set(functions, 0, 9);
		expect(!second.current(database, 0), "a read its stage has not brought up to date counts as changed");
		expect(second.current(database, 1), "a read its stage would keep holds");
		expect(throwsInternal(() -> first.get(database, 0)), "reading what its stage has not computed is an error");
		expect(throwsInternal(() -> first.end(database, 0, new Box(9))), "ending what was not begun is an error");
		first.begin(database, 0);
		var cycle = false;
		try
			first.begin(database, 0)
		catch (_:QueryCycle)
			cycle = true;
		expect(cycle, "beginning a key being computed is a cycle");
		first.end(database, 0, new Box(9));
		expect(first.get(database, 0).value == 9, "a computed key is read back");

		var checked = new QueryDatabase(true);
		database = checked;
		functions = checked.register(QueryKind.input("function", digestInt, sameInt));
		first = checked.register(new ComputedQueryKind<Box>("first", Box.same));
		second = checked.register(new ComputedQueryKind<Box>("second", Box.same));
		build([1, 2]);
		build([1, 2]);
		hidden = 1;
		var mismatch:Null<QueryReuseMismatch> = null;
		try
			build([1, 2])
		catch (error:QueryReuseMismatch)
			mismatch = error;
		hidden = 0;
		expect(mismatch != null && mismatch.query == "first(0)",
			"check mode computes a held rewrite again and compares");
	}

	/**
	 * A summary over per-function contributions: only a contribution that is not the one kept is applied, and a key that appears
	 * or goes changes only its readers and the readers of the whole set.
	 */
	static function summaries():Void {
		var database = new QueryDatabase();
		var functions = database.register(QueryKind.input("function", digestInt, sameInt));
		var uses = database.register(new ComputedQueryKind<Array<Int>>("uses",
			(left, right) -> left.join(",") == right.join(","), function(db, key) {
				var bits = db.get(functions, key);
				return [for (bit in 0...8) if (bits & (1 << bit) != 0) bit];
			}));
		var summary = database.register(new QuerySummary("used"));
		var keyRuns = [0, 0, 0, 0], wholeRuns = 0;
		var reader = database.register(new ComputedQueryKind<Box>("has", Box.same, function(db, key) {
			keyRuns[key]++;
			return new Box(summary.has(db, key) ? 1 : 0);
		}));
		var whole = database.register(new ComputedQueryKind<Box>("all", Box.same, function(db, _) {
			wholeRuns++;
			return new Box(summary.keys(db).length);
		}));
		function build(bits:Array<Int>):Void {
			database.newRevision();
			for (key in 0...bits.length)
				database.set(functions, key, bits[key]);
			summary.open(database);
			for (key in 0...bits.length)
				summary.contribute(database, key, uses.get(database, key));
			summary.close(database);
			for (key in 0...4)
				reader.get(database, key);
			whole.get(database, 0);
		}
		function present():String
			return [for (key in 0...4) reader.value(key).value].join("");
		build([1, 2, 1]);
		expect(summary.replaced == 3 && present() == "1100" && keyRuns.join("") == "1111" && wholeRuns == 1,
			"a first run");
		build([1, 2, 1]);
		expect(summary.replaced == 3 && keyRuns.join("") == "1111" && wholeRuns == 1,
			"contributions that held cost nothing, and nothing is read again");
		build([1, 6, 1]);
		expect(summary.replaced == 4 && present() == "1110" && keyRuns.join("") == "1121" && wholeRuns == 2,
			"a new key changes only its readers and the whole set");
		build([3, 6, 1]);
		expect(summary.replaced == 5 && keyRuns.join("") == "1121" && wholeRuns == 2,
			"a contribution naming a key another names changes no reader");
		build([3, 6]);
		expect(summary.replaced == 6 && keyRuns.join("") == "1121" && wholeRuns == 2,
			"a contributor not given is retracted");
		build([0, 6]);
		expect(summary.replaced == 7 && present() == "0110" && keyRuns.join("") == "2121" && wholeRuns == 3,
			"a key no contributor names any more goes");

		summary.open(database);
		expect(throwsInternal(() -> summary.has(database, 0)), "reading a summary while it is open is an error");
		summary.contribute(database, 0, uses.get(database, 0));
		expect(throwsInternal(() -> summary.contribute(database, 0, [])),
			"a contributor given twice in a run is an error");
		summary.open(database);
		summary.contribute(database, 0, uses.get(database, 0));
		summary.contribute(database, 1, uses.get(database, 1));
		summary.close(database);
		expect(summary.has(database, 1) && !summary.has(database, 0), "a run left open is started again");

		var checked = new QueryDatabase(true);
		var counted = checked.register(new QuerySummary("counted"));
		var given = [1, 2];
		counted.open(checked);
		counted.contribute(checked, 0, given);
		counted.close(checked);
		given.push(3);
		counted.open(checked);
		counted.contribute(checked, 0, given);
		expect(throwsInternal(() -> counted.close(checked)),
			"check mode counts again and finds a contribution changed after it was given");
	}

	/**
	 * Sweep drops the computed memos a build did not use, of the kinds it used that gained memos since they were last swept; a
	 * dropped memo is computed again when read.
	 */
	static function computedSweep():Void {
		var database = new QueryDatabase();
		var source = database.register(QueryKind.input("source", digestInt, sameInt));
		var used = database.register(new ComputedQueryKind<Box>("used", Box.same,
			(db, key) -> new Box(db.get(source, key))));
		var idle = database.register(new ComputedQueryKind<Box>("idle", Box.same,
			(db, key) -> new Box(db.get(source, key))));
		database.newRevision();
		for (key in 0...3)
			database.set(source, key, key);
		for (key in 0...3)
			used.get(database, key);
		idle.get(database, 0);
		database.newRevision();
		used.get(database, 0);
		expect(database.sweep() == 2,
			"the keys the build did not use are dropped, and a kind it did not use is left alone");
		var computations = database.computations;
		idle.get(database, 0);
		used.get(database, 0);
		expect(database.computations == computations, "what is kept holds");
		used.get(database, 1);
		expect(database.computations == computations + 1, "what was dropped is computed again");
		database.newRevision();
		used.get(database, 0);
		used.get(database, 1);
		expect(database.sweep() == 0, "a sweep drops nothing the build used");
		database.newRevision();
		used.get(database, 0);
		expect(database.sweep() == 0, "a kind that gained no memo since its last sweep is left alone");
		used.get(database, 1);
		expect(database.computations == computations + 1, "so what it holds still holds");
	}

	/**
	 * Computed memos take no part in transactions, but a rollback that undid results drops those computed after the commit it
	 * returns to: an undone result takes back an older change, against which they would hold.
	 */
	static function computedTransactions():Void {
		var database = new QueryDatabase();
		var written = new TestWritten(database);
		var source = database.register(QueryKind.input("source", digestInt, sameInt));
		for (_ in 0...2)
			written.own.push(0);
		var runs = 0;
		var reader = database.register(new ComputedQueryKind<Box>("over-written", Box.same, function(db, key) {
			runs++;
			db.record(written, key);
			return new Box(db.get(source, key) + written.latestChange(key));
		}));
		var start = database.newRevision();
		database.set(source, 0, 1);
		database.set(source, 1, 1);
		written.write(0, new RecordedResult(start, [QueryRead.of(written.index, 1)]));
		reader.get(database, 0);
		reader.get(database, 1);
		var taken = database.commit();
		expect(runs == 2, "computed in the build that is taken");

		var later = database.newRevision();
		written.own[1] = later;
		written.write(0, new RecordedResult(later, []));
		written.own[0] = later;
		reader.get(database, 0);
		expect(runs == 3, "a written result that changed recomputes its reader");
		database.rollBack(taken);
		written.own[0] = 0;
		written.own[1] = 0;
		reader.get(database, 0);
		expect(runs == 4, "what was computed over a result a rollback undid is computed again");
		reader.get(database, 1);
		expect(runs == 4, "what was computed before the commit holds");
		database.rollBack(taken);
		reader.get(database, 0);
		expect(runs == 4, "a rollback that undoes nothing drops nothing");
	}

	/**
	 * Values a stage puts, made from what it was given: an equal one keeps the object and the revision it changed at, so a reader
	 * holds; a key read in the revision changes in a later one, so the reader does not hold over the new value.
	 */
	static function putKinds():Void {
		var database = new QueryDatabase();
		var given = database.register(new ComputedQueryKind<Box>("given", Box.same));
		var runs = 0;
		var reader = database.register(new ComputedQueryKind<Box>("reader", Box.same, function(db, key) {
			runs++;
			return new Box(given.get(db, key).value * 10);
		}));
		database.newRevision();
		var first = new Box(1);
		expect(given.put(database, 0, first) == first, "a new key takes the value put");
		expect(reader.get(database, 0).value == 10 && runs == 1, "a reader computes over it");

		database.newRevision();
		expect(given.put(database, 0, first) == first, "the same object is kept");
		expect(given.put(database, 0, new Box(1)) == first, "an equal value keeps the object");
		reader.get(database, 0);
		expect(runs == 1, "a reader of a value put equal holds");

		database.newRevision();
		var revision = database.revision;
		reader.get(database, 0);
		var second = new Box(2);
		expect(given.put(database, 0, second) == second && database.revision > revision,
			"a key read in the revision changes in a later one");
		database.newRevision();
		given.put(database, 0, second);
		expect(reader.get(database, 0).value == 20 && runs == 2, "its reader computes again");

		given.clear();
		expect(throwsInternal(() -> given.get(database, 0)), "a cleared kind has no memos");
		expect(given.put(database, 0, first) == first, "and takes values again");
	}
}
