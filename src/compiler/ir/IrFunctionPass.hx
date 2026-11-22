package compiler.ir;

import compiler.ir.Ir.IrType;

/**
 * A stage before the encode point written per function, so a session reuses what it made of each function whose input and facts
 * are unchanged (`IrFunctionStages.run`). One object per run, made by the stage for that run: it holds the run's state.
 *
 * The run is: `summarize` each function, which depends on the function alone; `prepare` the whole-program step from the summaries;
 * `transform` each function, reading everything else it depends on through the reader (`IrFactReader.read`, computed by `fact`) and
 * asking for helpers through it (`IrFactReader.request`, made by `request`); `finish` the program from the rewritten functions.
 * A transform must read nothing about the program but through the reader, and have no side effect but its requests.
 */
interface IrFunctionPass {
	/** What the whole-program step needs of `fn`, as a number: it may depend on `fn` alone. */
	function summarize(fn:IrFunction):Int;

	/**
	 * The whole-program step, from the functions in program order and their summaries. `names` indexes them: in a session, through
	 * the program's shared index (`IrLineage.named`).
	 */
	function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void;

	/** The value of this stage's fact of `kind` and `key`, as the program stands after `prepare`. */
	function fact(kind:Int, key:String):Int;

	/** `fn` rewritten: `fn` itself when the stage leaves it alone. */
	function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction;

	/** Makes the helper that `type` asks for, when it is not made yet; called in the order the rewrites asked. */
	function request(type:IrType):Void;

	/** The program's functions from the rewritten ones, in program order: the helpers the stage made added. */
	function finish(functions:Array<IrFunction>):Array<IrFunction>;
}
