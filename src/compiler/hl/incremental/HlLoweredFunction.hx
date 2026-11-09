package compiler.hl.incremental;

import compiler.ir.IrFunction;
import compiler.ir.hl.HlLoweringView.HlFact;

/**
 * A lowered function with everything it leans on outside itself: the requests lowering made to the symbol tables and the function
 * layout (`HlSymbolRequest`), and the facts it read about object types (`HlLoweringView`). The function's own code stays valid for
 * any build in which the IR (`source`) is the same, the facts hold and the requests have answers; `HlLink` gives it the indices of
 * that build.
 */
class HlLoweredFunction {
	public final name:String;

	/** The final IR the function was lowered from. */
	public final source:IrFunction;

	/** The code, with the indices of the build that lowered it. */
	public final fn:HlFunction;

	public final requests:Array<HlSymbolRequest>;
	public final facts:Array<HlFact>;

	public function new(name:String, source:IrFunction, fn:HlFunction, requests:Array<HlSymbolRequest>, facts:Array<HlFact>) {
		this.name = name;
		this.source = source;
		this.fn = fn;
		this.requests = requests;
		this.facts = facts;
	}

	/** The same lowering, for an IR function that compares equal to its source (so the next comparison is by identity). */
	public function from(equalSource:IrFunction):HlLoweredFunction
		return new HlLoweredFunction(name, equalSource, fn, requests, facts);
}
