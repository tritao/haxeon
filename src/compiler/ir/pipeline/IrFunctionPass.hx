package compiler.ir.pipeline;

import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrFunction;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.verify.IrVerifier;

/**
 * A stage before the encode point written per function, so a session reuses what it made of each function whose input and facts
 * are unchanged (`IrFunctionStages.run`). One object per run, made by the stage for that run: it holds the run's state.
 *
 * The run is: `summarize` each function, which depends on the function alone; `prepare` the whole-program step from the summaries;
 * `transform` each function, reading everything else it depends on through the reader (`IrFactReader.read`, computed by `fact`) and
 * asking for helpers through it (`IrFactReader.request`, made by `request`); `finish` the program from the rewritten functions.
 * A transform must read nothing about the program but through the reader, and have no side effect but its requests.
 *
 * A class, not an interface, as `IrFactSource` is: the run calls it per function.
 */
class IrFunctionPass extends IrFactSource {
	/** What the whole-program step needs of `fn`, as a number: it may depend on `fn` alone. */
	public function summarize(fn:IrFunction):Int
		throw unimplemented();

	/**
	 * The whole-program step, from the functions in program order and their summaries, which `names` indexes by name.
	 */
	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void
		throw unimplemented();

	/** `fn` rewritten: `fn` itself when the stage leaves it alone. */
	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction
		throw unimplemented();

	/**
	 * Makes the helper of `kind` (the stage's own numbering) for `type` and `name` (what else the stage keys the helper by, such as
	 * the static it checks), when it is not made yet; called in the order the rewrites asked.
	 */
	public function request(kind:Int, type:IrType, name:Null<String>):Void
		throw unimplemented();

	/** The program's functions from the rewritten ones, in program order: the helpers the stage made added. */
	public function finish(functions:Array<IrFunction>):Array<IrFunction>
		throw unimplemented();
}

/**
 * What a stage's facts are computed from (`IrStageFacts`): a per-function stage (`IrFunctionPass`), or a stage that drives its own
 * run and records its facts all the same (`IrInliner`, through `IrFacts`). A class, not an interface: HashLink calls an
 * interface's methods by name, through a virtual made at each conversion, and a fact is read per function and stage.
 */
class IrFactSource {
	/** The space of the run its facts are computed in (`IrStageFacts.run`); -1 before one starts. */
	public var space = -1;

	/** The value of the stage's fact of `kind` and `key`, as the program stands in this run (after `prepare`, for a pass). */
	public function fact(kind:Int, key:String):Int
		throw unimplemented();

	function unimplemented():compiler.core.InternalError
		return new compiler.core.InternalError("A stage defines every method its run calls");
}

/**
 * A helper a rewrite asked for (`IrFactReader.request`): the kind the stage numbers its helpers by, the type it is for, and the name
 * it is for when the stage keys it by one too.
 */
class IrStageRequest {
	public final kind:Int;
	public final type:IrType;
	public final name:Null<String>;

	public function new(kind:Int, type:IrType, name:Null<String>) {
		this.kind = kind;
		this.type = type;
		this.name = name;
	}

	/** Whether two lists of requests ask for the same helpers in the same order, for `--check-reuse`. */
	public static function same(left:Null<Array<IrStageRequest>>, right:Null<Array<IrStageRequest>>):Bool {
		var leftCount = left == null ? 0 : left.length, rightCount = right == null ? 0 : right.length;
		if (leftCount != rightCount)
			return false;
		if (left != null && right != null)
			for (index in 0...leftCount)
				if (left[index].kind != right[index].kind || left[index].name != right[index].name
					|| !IrVerifier.sameType(left[index].type, right[index].type))
					return false;
		return true;
	}
}
