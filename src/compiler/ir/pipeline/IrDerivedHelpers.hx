package compiler.ir.pipeline;

import compiler.core.InternalError;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;

/**
 * The helpers a stage makes from the program's declarations rather than from its functions (the reflection helpers): each is made
 * through `IrFunctionStages.derived`, from its name, and reads what it is made of as facts whose value is a print of the declaration
 * (`print`, the stage's text of the declaration of a kind and key, interned). In a session a helper whose declarations print the same
 * is last build's; without one, nothing is printed.
 */
@:nullSafety(Strict)
class IrDerivedHelpers extends IrFunctionPass {
	final stage:String;
	final stageMemos:Null<IrStageMemos>;
	final builder:Null<IrBodyBuilder>;

	/** The text of the declaration of `kind` (the stage's numbering) and `key`, which the stage sets before it makes a helper. */
	public var print:(kind:Int, key:String) -> String = (_, _) -> "";

	/** Helpers for `stage`; in a session with `stageMemos`, frozen past the encode point. */
	public function new(stage:String, ?stageMemos:IrStageMemos, ?builder:IrBodyBuilder) {
		this.stage = stage;
		this.stageMemos = stageMemos;
		this.builder = builder;
		// The declarations are this run's: what a fact printed before is printed again when next asked for.
		if (stageMemos != null)
			stageMemos.stageFacts.run(stageMemos.database, stage + HELPERS, this);
	}

	/** What the space of the helpers' facts is named after the stage: the stage's own pass computes its own facts. */
	static inline final HELPERS = ":helpers";

	/** The helper `name`, which `make` makes, reading the declarations it is made of through the reader. */
	public function make(name:String, make:IrFactReader->IrFunction):IrFunction
		return IrFunctionStages.derived(stage, name, this, IrFunctionStages.FROM_NAME, stageMemos, builder, make);

	override public function fact(kind:Int, key:String):Int {
		var known = stageMemos;
		return known == null ? 0 : known.stageFacts.intern(print(kind, key));
	}

	override public function summarize(fn:IrFunction):Int
		return 0;

	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {}

	override public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction
		return fn;

	override public function request(kind:Int, type:IrType, name:Null<String>):Void
		throw new InternalError('The helpers of $stage ask for no other helper');

	override public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;
}
