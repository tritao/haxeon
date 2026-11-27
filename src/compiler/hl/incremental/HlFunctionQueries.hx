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
 * and the plain build's reachability walk (`IrWalkMemo`), whose result holds while what it read of the program did not change. The
 * copies of the session state share them; a compile that keeps no session has none.
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

	public function new(database:QueryDatabase) {
		this.database = database;
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
