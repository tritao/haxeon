package compiler.hl.incremental;

import compiler.ir.hl.HlLoweringView.HlFact;

/**
 * A lowered function with everything it leans on outside itself: the requests lowering made to the symbol tables and the function
 * layout (`HlSymbolRequest`), and the facts it read about object types (`HlLoweringView`). The function's own code stays valid for
 * any build in which the IR is the same, the facts hold and the requests have answers; `HlLink` gives it the indices of that build.
 */
class HlLoweredFunction {
	public final name:String;
	public final fn:HlFunction;
	public final requests:Array<HlSymbolRequest>;
	public final facts:Array<HlFact>;

	public function new(name:String, fn:HlFunction, requests:Array<HlSymbolRequest>, facts:Array<HlFact>) {
		this.name = name;
		this.fn = fn;
		this.requests = requests;
		this.facts = facts;
	}
}
