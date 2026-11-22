package compiler.ir;

import compiler.ir.Ir.IrType;
import compiler.ir.IrStageMemo.IrLineage;

/** What a rewrite reads about the program and the helpers it asks for, recorded for its memo entry when it has one. */
class IrFactReader {
	final pass:IrFunctionPass;
	final facts:Null<IrFacts>;
	final spaces:Array<Int> = [];
	final stage:String;
	var number = 0;
	var reads:Array<Int> = [];
	var asked:Null<Array<IrType>> = null;

	/** Records without making the helpers: a check-mode rewrite whose result is compared, not used. */
	var checking = false;

	/** A reader for `pass`; with `facts`, it records what it reads. */
	public function new(stage:String, pass:IrFunctionPass, ?facts:IrFacts) {
		this.stage = stage;
		this.pass = pass;
		this.facts = facts;
	}

	/** The value of the stage's fact of `kind` and `key` (`IrFunctionPass.fact`). */
	public function read(kind:Int, key:String):Int {
		var table = facts;
		if (table == null)
			return pass.fact(kind, key);
		while (spaces.length <= kind)
			spaces.push(-1);
		if (spaces[kind] < 0)
			spaces[kind] = table.space(stage, kind);
		var id = table.id(spaces[kind], kind, key), print = table.print(id, pass);
		if (table.firstRead(id, number)) {
			reads.push(id);
			reads.push(print);
		}
		return table.value(id);
	}

	/** Asks for the helper of `type` (`IrFunctionPass.request`). */
	public function request(type:IrType):Void {
		if (facts != null) {
			var list = asked;
			if (list == null)
				asked = list = [];
			list.push(type);
		}
		if (!checking)
			pass.request(type);
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
	public function recorded():Array<Int>
		return reads.length == 0 ? IrLineage.NO_FACTS : reads;

	/** The helpers asked for since `begin`, or null. */
	public function requests():Null<Array<IrType>>
		return asked;
}
