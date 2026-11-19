import compiler.query.Digest;
import compiler.query.QueryDatabase;
import compiler.query.QueryErrors.QueryCycle;
import compiler.query.QueryErrors.QueryReuseMismatch;
import compiler.query.QueryKind;

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

		Sys.println("PASS: query engine reuses, cuts off early, verifies reads in order, reports cycles, sweeps and checks reuse");
	}
}
