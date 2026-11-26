package compiler.ir.reuse;

import compiler.ir.model.Ir;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIds;

/**
 * A whole-program walk a session keeps with what it read, so the next build takes its result while the program gives the walk the
 * same, and walks again otherwise. Every kept walk reads the same kinds of input: the program's tables (classes, interfaces, natives,
 * C natives, static fields, enums), what its caller gives it (roots and settings as names, root types), the declaration of each
 * function it may read, and of each function it reached, a summary `S` of that function's edges. A build with the same tables and
 * given inputs, whose functions are the same objects or, for one that is not, the same declaration and, when it was reached, a
 * summary with the same edges, walks to the same result `R`: a function the walk did not reach adds nothing through its body.
 *
 * The tables are kept as copies of the program's lists (`IrWalkTables`).
 */
@:nullSafety(Strict)
class IrWalkRecord<S, R> {
	final tables:IrWalkTables;

	/** What the caller gave the walk besides the program: its roots and settings, as names and as type ids. */
	final given:Array<String>;

	final givenTypes:Array<Int>;

	/** The functions whose declarations the walk read. */
	final functions:Array<IrFunction>;

	/** By position in `functions`: the summary the walk followed, or null for a function it did not reach. */
	final summaries:Array<Null<S>>;

	public final result:R;

	/** The record of a walk of `program`, given `given` and `givenTypes`, that read `functions` and `summaries` and found `result`. */
	public function new(program:IrProgram, given:Array<String>, givenTypes:Array<Int>, functions:Array<IrFunction>,
			summaries:Array<Null<S>>, result:R) {
		tables = new IrWalkTables(program);
		this.given = given;
		this.givenTypes = givenTypes;
		this.functions = functions;
		this.summaries = summaries;
		this.result = result;
	}

	/**
	 * This walk's result as the record of a walk of `program` now; null when the program or the caller gives the walk something else.
	 * `read(fn, last)` is the summary of reached function `fn` now when it has the edges of `last`, else null. A function that stayed
	 * is not looked at: the record keeps its summary, which a walk done again takes back (`eachSummary`).
	 */
	public function holds(program:IrProgram, given:Array<String>, givenTypes:Array<Int>, functions:Array<IrFunction>,
			read:(IrFunction, S) -> Null<S>):Null<IrWalkRecord<S, R>> {
		if (functions.length != this.functions.length || !IrObjectTools.sameNames(given, this.given)
			|| !IrTypeIds.sameList(givenTypes, this.givenTypes) || !tables.holds(program))
			return null;
		var kept:Null<Array<Null<S>>> = null;
		for (index in 0...functions.length) {
			var fn = functions[index], last = this.functions[index];
			if (fn == last)
				continue;
			var summary = summaries[index];
			if (fn.name != last.name || !IrWalkTables.sameDeclaration(fn, last))
				return null;
			if (summary == null)
				continue;
			var now = read(fn, summary);
			if (now == null)
				return null;
			if (kept == null)
				kept = summaries.copy();
			kept[index] = now;
		}
		return new IrWalkRecord(program, given, givenTypes, functions.copy(), kept ?? summaries, result);
	}

	/**
	 * Gives `memo` back the summaries the walk followed of the functions it read, for a walk done again:
	 * while the record held, nothing asked the memo for them, so it may have let them go.
	 */
	public function giveBack(memo:compiler.ir.reuse.IrStageMemos.IrContributionMemo<S>):Void
		for (index in 0...functions.length) {
			var summary = summaries[index];
			if (summary == null)
				continue;
			var version = functions[index].version;
			if (memo.get(version) == null)
				memo.keep(version, summary);
		}

	/** Tells `each` of every reached function and the summary the walk followed, for a walk done again (`giveBack`). */
	public function eachSummary(each:(IrFunction, S) -> Void):Void
		for (index in 0...functions.length) {
			var summary = summaries[index];
			if (summary != null)
				each(functions[index], summary);
		}
}
