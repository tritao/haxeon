package compiler.ir.reuse;

import compiler.ir.pipeline.IrFunctionPass.IrFactSource;
import compiler.ir.pipeline.IrFunctionPass.IrStageRequest;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.model.Ir.IrType;
import compiler.ir.reuse.IrStageMemo.IrLineage;

/** What a rewrite reads about the program and the helpers it asks for, recorded for its memo entry when it has one. */
@:nullSafety(Strict)
class IrFactReader {
	final source:IrFactSource;
	final pass:Null<IrFunctionPass>;
	final facts:Null<IrFacts>;
	final spaces:Array<Int> = [];
	final stage:String;
	var number = 0;
	var reads:Array<Int> = [];
	var asked:Null<Array<IrStageRequest>> = null;

	/** Records without making the helpers: a check-mode rewrite whose result is compared, not used. */
	var checking = false;

	/**
	 * A reader for `pass`; with `facts`, it records what it reads. A stage that is no `IrFunctionPass` gives no pass but the `source`
	 * of its facts, and asks for no helpers.
	 */
	public function new(stage:String, pass:Null<IrFunctionPass>, ?facts:IrFacts, ?source:IrFactSource) {
		this.stage = stage;
		this.pass = pass;
		this.facts = facts;
		var from:Null<IrFactSource> = source != null ? source : pass;
		if (from == null)
			throw new compiler.core.InternalError('The fact reader of $stage has nothing to compute its facts');
		this.source = from;
	}

	/** Whether it records what it reads: a reader without a memo only computes, so a pass may read its tables directly. */
	public function records():Bool
		return facts != null;

	/** The value of the stage's fact of `kind` and `key` (`IrFactSource.fact`). */
	public function read(kind:Int, key:String):Int {
		var table = facts;
		if (table == null)
			return source.fact(kind, key);
		while (spaces.length <= kind)
			spaces.push(-1);
		if (spaces[kind] < 0)
			spaces[kind] = table.space(stage, kind);
		var id = table.id(spaces[kind], kind, key), print = table.print(id, source);
		if (table.firstRead(id, number)) {
			reads.push(id);
			reads.push(print);
		}
		return table.value(id);
	}

	/** Asks for the helper of `kind` for `type` and `name` (`IrFunctionPass.request`). */
	public function request(kind:Int, type:IrType, ?name:String):Void {
		var maker = pass;
		if (maker == null)
			throw new compiler.core.InternalError('Stage $stage asked for a helper through a reader without a pass');
		if (facts != null) {
			var list = asked;
			if (list == null)
				asked = list = [];
			list.push(new IrStageRequest(kind, type, name));
		}
		if (!checking)
			maker.request(kind, type, name);
	}

	/** Starts the reads of one rewrite. */
	public function begin(checks:Bool):Void {
		var table = facts;
		if (table != null)
			number = table.newReader();
		reads = [];
		asked = null;
		checking = checks;
	}

	/** The facts read since `begin`, pairs of a fact and its print. */
	public function recorded():Array<Int> {
		var table = facts;
		return reads.length == 0 ? IrLineage.NO_FACTS : table == null ? reads : table.shared(reads);
	}

	/** The helpers asked for since `begin`, or null. */
	public function requests():Null<Array<IrStageRequest>>
		return asked;
}
