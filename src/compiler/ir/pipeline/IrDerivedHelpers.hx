package compiler.ir.pipeline;

import compiler.core.InternalError;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIds;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemo.IrLineage;

/**
 * The helpers a stage makes from the program's declarations rather than from its functions (the reflection helpers): each is made
 * through `IrFunctionStages.derived`, from its name, and reads what it is made of as facts whose value is a print of the declaration
 * (`print`, the stage's text of the declaration of a kind and key, interned). In a session a helper whose declarations print the same
 * is last build's; without one, nothing is printed.
 */
@:nullSafety(Strict)
class IrDerivedHelpers implements IrFunctionPass {
	final stage:String;
	final lineage:Null<IrLineage>;
	final checks:Bool;
	final types:Null<IrTypeIds>;
	final builder:Null<IrBodyBuilder>;

	/** The text of the declaration of `kind` (the stage's numbering) and `key`, which the stage sets before it makes a helper. */
	public var print:(kind:Int, key:String) -> String = (_, _) -> "";

	/** Helpers for `stage`; in a session with `lineage`, made with `types` and frozen past the encode point. */
	public function new(stage:String, ?lineage:IrLineage, checks = false, ?types:IrTypeIds, ?builder:IrBodyBuilder) {
		this.stage = stage;
		this.lineage = lineage;
		this.checks = checks;
		this.types = types;
		this.builder = builder;
	}

	/** The helper `name`, which `make` makes, reading the declarations it is made of through the reader. */
	public function make(name:String, make:IrFactReader->IrFunction):IrFunction {
		var known = types;
		if (lineage == null || known == null) {
			var reader = new IrFactReader(stage, this);
			reader.begin(false);
			return make(reader);
		}
		return IrFunctionStages.derived(stage, name, this, IrFunctionStages.FROM_NAME, lineage, checks, known, builder,
			make);
	}

	public function fact(kind:Int, key:String):Int {
		var known = lineage;
		return known == null ? 0 : known.memos.facts.intern(print(kind, key));
	}

	public function summarize(fn:IrFunction):Int
		return 0;

	public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {}

	public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction
		return fn;

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		throw new InternalError('The helpers of $stage ask for no other helper');

	public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;
}
