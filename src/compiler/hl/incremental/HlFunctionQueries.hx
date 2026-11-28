package compiler.hl.incremental;

import compiler.hl.IrSharedRuntimeCalls.SharedCalls;
import compiler.ir.analysis.IrNonNullFields.IrFieldKeys;
import compiler.ir.analysis.IrNonNullFields.IrFieldStores;
import compiler.ir.analysis.IrReachability.IrBodyEdges;
import compiler.ir.model.Ir.IrNative;
import compiler.ir.model.IrFunction;
import compiler.ir.reuse.IrFunctionValues;
import compiler.ir.reuse.IrStageMemos.IrContributionSummary;
import compiler.ir.reuse.IrWalkMemo;
import compiler.query.ComputedQueryKind;
import compiler.query.QueryDatabase;

/**
 * The HashLink backend's steps over the final IR as kinds of the session's database (docs/design/QUERY_ENGINE.md, slice 6): what
 * each works out from one function alone, kept while the function is the same object (`IrFunctionValues`, `IrContributionSummary`),
 * the plain build's reachability walk (`IrWalkMemo`), whose result holds while what it read of the program did not change, and
 * what lowering made of each function (`lowered`), which holds while the facts it read did not change. The copies of the session
 * state share them; a compile that keeps no session has none.
 */
class HlFunctionQueries {
	public final database:QueryDatabase;

	/** The text of each function and declaration in the runtime ABI (`RuntimeAbi.describe`). */
	public final abi:compiler.abi.RuntimeAbi.RuntimeAbiTexts;

	/** The runtime natives each function's rows call (`HlLower.discoverRuntimeNatives`). */
	public final natives:IrFunctionValues<Array<IrNative>>;

	/** The field stores each function makes (`IrNonNullFields`), with the field keys they name, which only grow. */
	public final fieldStores:IrFunctionValues<IrFieldStores>;

	public final fieldKeys = new IrFieldKeys();

	/** Each function's form with its runtime calls through helpers (`IrSharedRuntimeCalls`), and the helpers by name. */
	public final sharedCalls:IrFunctionValues<SharedCalls>;

	public final sharedHelpers:ComputedQueryKind<IrFunction>;

	/** The enums each function may need boxed descriptors of (`IrEnumRuntimeTypes.declarations`). */
	public final enumUses:IrContributionSummary<String>;

	/** The plain build's walk from the entry and its trim of the tables (`HlPlainBuild.reachable`). */
	public final plainReach:IrWalkMemo<IrBodyEdges, HlPlainBuild.HlPlainNames>;

	/**
	 * By the number of a function's name, what a plain build's lowering made of it: its code and requests, kept while the function is
	 * its source or equal to it and every fact the lowering read (`HlLoweringView`) has the value it read. Nothing reads a memo through
	 * the database, so a value made again is not compared.
	 */
	public final lowered:ComputedQueryKind<HlLoweredFunction>;

	/** The facts lowering reads, of the session's kind of them (`IrStageFacts`), and the answers they were worked out from. */
	public final facts:compiler.ir.reuse.IrStageFacts;

	public final loweringAnswers = new compiler.hl.lower.HlLoweringView.HlLoweringAnswers();

	/** The numbers of the requests the lowered functions made (`HlLoweredFunction.keys`), which only grow. */
	public final requestKeys = new HlRequestKeys();

	public function new(database:QueryDatabase, facts:compiler.ir.reuse.IrStageFacts) {
		this.database = database;
		this.facts = facts;
		lowered = database.register(new ComputedQueryKind<HlLoweredFunction>("hl-lowered",
			(left, right) -> left == right,
			null, key -> compiler.ir.model.IrSymbol.ofFunctionKey(key).name));
		abi = new compiler.abi.RuntimeAbi.RuntimeAbiTexts(database);
		natives = new IrFunctionValues<Array<IrNative>>(database, "hl-runtime-natives", sameNatives);
		fieldStores = new IrFunctionValues<IrFieldStores>(database, "hl-field-stores",
			(left, right) -> left.same(right));
		sharedCalls = new IrFunctionValues<SharedCalls>(database, "hl-shared-calls", SharedCalls.same);
		sharedHelpers = database.register(new ComputedQueryKind<IrFunction>("hl-shared-helpers",
			(left, right) -> left == right, null, key -> compiler.ir.model.IrSymbol.ofFunctionKey(key).name));
		enumUses =
			new IrContributionSummary<String>(database.register(new compiler.query.QuerySummary("hl-enum-uses")));
		plainReach = database.register(new IrWalkMemo<IrBodyEdges, HlPlainBuild.HlPlainNames>("hl-plain-reach",
			IrBodyEdges.same, null));
	}

	/**
	 * The memo of what lowering made of `fn` in `slot` of `lowered`, when it holds for `fn`: made from `fn` or from a function equal
	 * to it, which `fn` then replaces as its source, and nothing it read changed. Null otherwise.
	 */
	public function loweredFor(slot:Int, fn:IrFunction):Null<HlLoweredFunction> {
		if (lowered.verifiedIn(slot) == 0)
			return null;
		var entry = lowered.value(slot), source = entry.source;
		if (source != fn && !compiler.ir.codec.IrFunctionStateEquality.same(source, fn))
			return null;
		if (!lowered.current(database, slot))
			return null;
		if (source != fn) {
			entry = entry.from(fn);
			lowered.replace(slot, entry);
		}
		return entry;
	}

	/** Whether two lists of natives name the same ones in the same order. */
	static function sameNatives(left:Array<IrNative>, right:Array<IrNative>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length)
			if (left[index].name != right[index].name || left[index].symbol != right[index].symbol)
				return false;
		return true;
	}
}
