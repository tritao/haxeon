package compiler.hl.incremental;

import compiler.ir.model.IrFunction;

/**
 * A lowered function with everything it leans on outside itself: the requests lowering made to the symbol tables and the function
 * layout (`HlSymbolRequest`, numbered by `HlRequestKeys`), and the facts it read about object types (`HlLoweringView`). The
 * function's own code stays valid for any build in which the IR (`source`) is the same, the facts hold and the requests have
 * answers; `HlLink.relocate` finds where that build's tables hold what it names.
 */
class HlLoweredFunction {
	public final name:String;

	/** The final IR the function was lowered from. */
	public final source:IrFunction;

	/** The code, with the indices of the build that lowered it. */
	public final fn:HlFunction;

	/** The distinct requests lowering made, by number (`HlRequestKeys`), in the order it first made them. */
	public final keys:Array<Int>;

	/** The answer each of `keys` got, which is the index `fn` uses for it. */
	public final answers:Array<Int>;

	/** The facts lowering read, as pairs of a fact and the print it had (`HlLoweringView`, `IrFacts`). */
	public final facts:Array<Int>;

	/**
	 * What the code names, as pairs of a table (`HlSectionWriter`'s use kinds) and an index of `fn`, in the order a section's
	 * encoding meets them: made from `fn` the first time a section is written with it, and shared by the copies.
	 */
	public var uses:Null<Array<Int>> = null;

	public function new(name:String, source:IrFunction, fn:HlFunction, keys:Array<Int>, answers:Array<Int>,
			facts:Array<Int>) {
		this.name = name;
		this.source = source;
		this.fn = fn;
		this.keys = keys;
		this.answers = answers;
		this.facts = facts;
	}

	/** The same lowering, for an IR function that compares equal to its source (so the next comparison is by identity). */
	public function from(equalSource:IrFunction):HlLoweredFunction {
		var result = new HlLoweredFunction(name, equalSource, fn, keys, answers, facts);
		result.uses = uses;
		return result;
	}

	public function renamed(next:String):HlLoweredFunction {
		var result = new HlLoweredFunction(next, source, fn, keys, answers, facts);
		result.uses = uses;
		return result;
	}
}
