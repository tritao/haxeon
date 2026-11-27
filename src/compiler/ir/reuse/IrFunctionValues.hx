package compiler.ir.reuse;

import compiler.ir.model.IrFunction;
import compiler.query.QueryDatabase;
import compiler.query.QueryKind.QueryKindBase;
import compiler.query.QueryKind.QueryRead;

/**
 * What a whole-program step over the final IR works out from one function alone (its signature text, the natives its rows call, the
 * field stores it makes), as a kind of the session's database keyed by the number of the function's name: a value holds while it
 * was made from the same function object (`IrFunction.version`, never given twice), which is never changed once made. Nothing reads
 * a value through the database, so a value has no revisions of its own: the columns are the value, the version it was made from and
 * the last revision a build asked for it, by which the database sweeps the values no build asked for (docs/design/QUERY_ENGINE.md,
 * Whole-program steps). A rollback leaves them: a value is right for its function object whichever build made it.
 *
 * `@:generic`: one per value type, whose values are a typed column.
 */
@:generic
class IrFunctionValues<V> extends QueryKindBase {
	final database:QueryDatabase;

	/** Whether two values of one function read the same to the step (`--check-reuse`). */
	public final same:(V, V) -> Bool;

	/** By key: the value, the version of the function it was made from (0 for none), and the last revision it was asked for. */
	var values:Array<Null<V>> = [];

	var from:Array<Int> = [];
	var askedIn:Array<Int> = [];

	/** The last revision a value was asked for or kept: a sweep leaves a kind the build did not use alone. */
	var usedAt = 0;

	/** Whether a key gained a value since the last sweep: a kind that gained none holds no more values than the sweep left. */
	var grown = false;

	public function new(database:QueryDatabase, name:String, same:(V, V) -> Bool) {
		super(name);
		this.database = database;
		this.same = same;
		database.register(this);
	}

	/** The value made from `fn`; null when there is none, and the caller makes it (`keep`). */
	public function of(fn:IrFunction):Null<V> {
		var key = fn.symbol.functionKey();
		if (key >= from.length || from[key] != fn.version)
			return null;
		var revision = database.revision;
		askedIn[key] = revision;
		usedAt = revision;
		return values[key];
	}

	/** Keeps `value`, made from `fn` alone, and returns it. */
	public function keep(fn:IrFunction, value:V):V {
		var key = fn.symbol.functionKey(), revision = database.revision;
		if (key >= from.length) {
			// As long as the names numbered, with a little room: half again would leave a third of each column empty.
			var named = compiler.ir.model.IrSymbol.functionKeysGiven(), length = key + 1 > named ? key + 1 : named;
			length += length >> 4;
			values.resize(length);
			QueryRead.extend(from, length);
			QueryRead.extend(askedIn, length);
		}
		if (from[key] == 0)
			grown = true;
		values[key] = value;
		from[key] = fn.version;
		askedIn[key] = revision;
		usedAt = revision;
		return value;
	}

	override public function sweep(since:Int):Int {
		if (usedAt < since || !grown)
			return 0;
		grown = false;
		var dropped = 0;
		for (key in 0...from.length)
			if (from[key] != 0 && askedIn[key] < since) {
				from[key] = 0;
				values[key] = null;
				dropped++;
			}
		return dropped;
	}
}
