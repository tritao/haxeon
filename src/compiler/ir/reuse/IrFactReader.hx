package compiler.ir.reuse;

import compiler.ir.model.Ir.IrType;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionPass.IrStageRequest;
import compiler.query.QueryDatabase;

/**
 * What a rewrite reads about the program (`IrStageFacts`) and the helpers it asks for. In a session each read is a read of the
 * query being computed, the memo of what the stage makes of the function (`IrFunctionStages.run`); a compile without a session
 * reads the same facts, computed once per run, through the same reader.
 */
@:nullSafety(Strict)
class IrFactReader {
	final facts:Null<IrStageFacts>;
	final space:Int;
	final pass:IrFunctionPass;
	final database:Null<QueryDatabase>;

	/** The ids of the stage's facts by kind and key, as `IrStageFacts.id` gave them, so a key is interned once per run. */
	final known:Array<Map<String, Int>> = [];

	var asked:Null<Array<IrStageRequest>> = null;

	/** Records without making the helpers: a check-mode rewrite whose result is compared, not used. */
	var checking = false;

	/**
	 * A reader for `pass`, which computes the facts and makes the helpers its rewrites ask for: of its space in `facts` (the run
	 * `IrStageFacts.run` started), recorded in `database` when there is one; without `facts`, each read is computed at once.
	 */
	public function new(pass:IrFunctionPass, facts:Null<IrStageFacts>, database:Null<QueryDatabase>) {
		this.pass = pass;
		this.facts = facts;
		this.space = pass.space;
		this.database = database;
	}

	/** The value of the stage's fact of `kind` and `key` (`IrFactSource.fact`). */
	public function read(kind:Int, key:String):Int {
		var facts = this.facts;
		if (facts == null)
			return pass.fact(kind, key);
		while (known.length <= kind)
			known.push([]);
		var table = known[kind], id = table.get(key);
		if (id == null) {
			id = facts.id(space, kind, key);
			table.set(key, id);
		}
		return facts.read(database, id);
	}

	/** Asks for the helper of `kind` for `type` and `name` (`IrFunctionPass.request`). */
	public function request(kind:Int, type:IrType, ?name:String):Void {
		var list = asked;
		if (list == null)
			asked = list = [];
		list.push(new IrStageRequest(kind, type, name));
		if (!checking)
			pass.request(kind, type, name);
	}

	/** Starts the reads of one rewrite. */
	public function begin(checks:Bool):Void {
		asked = null;
		checking = checks;
	}

	/** The helpers asked for since `begin`, or null. */
	public function requests():Null<Array<IrStageRequest>>
		return asked;
}
