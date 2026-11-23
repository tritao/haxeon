package compiler.ir.verify;

import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrDeclarationEquality;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrFunction.IrFunctionKind;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.reuse.IrFacts;

/**
 * What the last build's verification learned: the functions it accepted, with the facts each acceptance leaned on. A function is
 * verified again only when it is another function or when something it read gives another answer, so a build that changes a few
 * functions verifies those, and the functions that call them, and not the whole program.
 *
 * The verifier reads the program through `IrVerifyTable`s; every `get` and `exists` of a function's check is recorded as an answer
 * fact (`IrFacts`) of the table's kind, its answer compared part by part (`sameAnswer`). A table has no way to iterate, so a
 * function-level check cannot read what it did not record.
 */
class IrVerifyMemo extends IrFacts.IrAnswerSource {
	/** The tables a read can be of, in the order of their kinds; a table of another name takes the next kind. */
	static inline final SPACE = "verify";

	final accepted:Map<String, {fn:IrFunction, facts:Array<Int>}> = [];
	final facts = new IrFacts();
	final kinds:Map<String, Int> = [];
	final names:Array<String> = [];
	final spaces:Array<Int> = [];
	final lookups:Array<Null<String->Dynamic>> = [];

	/** The reader number and the facts of the function being checked, pairs of a fact and its print. */
	var reader = 0;

	var reads:Array<Int> = [];

	/** Whether the tables are noting their reads: from `begin` to `accept` or `abandon`. */
	public var recordingFunction = false;

	/** The functions whose inline-enum check passed, and what that check read besides the function (see `IrVerifier`). */
	public final enumChecked:Map<String, IrFunction> = [];

	public var enumContext = "";

	/** How many functions the last verification checked, and how many it took from the memo. */
	public var checkedFunctions = 0;

	public var skippedFunctions = 0;

	public function new()
		super();

	/** Starts a build: the tables the reads are answered from. */
	public function attach(named:Map<String, String -> Dynamic>):Void {
		checkedFunctions = 0;
		skippedFunctions = 0;
		for (index in 0...lookups.length)
			lookups[index] = null;
		for (name => lookup in named)
			lookups[kindOf(name)] = lookup;
		facts.startBuild();
		facts.begin();
	}

	/** The kind of the reads of table `name`. */
	public function kindOf(name:String):Int {
		var known = kinds.get(name);
		if (known != null)
			return known;
		var made = names.length;
		kinds.set(name, made);
		names.push(name);
		spaces.push(facts.space(SPACE, made));
		lookups.push(null);
		return made;
	}

	public function begin():Void {
		reader = facts.newReader();
		reads = [];
		recordingFunction = true;
	}

	/** Records the read of `key` in the table of `kind`, once per function. */
	public function note(kind:Int, key:String):Void {
		var id = facts.id(spaces[kind], kind, key);
		if (facts.firstRead(id, reader)) {
			reads.push(id);
			reads.push(facts.printAnswer(id, this));
		}
	}

	/** Ends the check of `fn` and remembers what it read. */
	public function accept(fn:IrFunction):Void {
		checkedFunctions++;
		accepted.set(fn.name, {fn: fn, facts: reads});
		reads = [];
		recordingFunction = false;
	}

	public function abandon():Void
		recordingFunction = false;

	/** Whether `fn` was accepted by an earlier build and everything it read still gives the same answer. */
	public function holds(fn:IrFunction):Bool {
		var known = accepted.get(fn.name);
		if (known == null || (known.fn != fn && !compiler.ir.codec.IrFunctionStateEquality.same(known.fn, fn)))
			return false;
		var read = known.facts, index = 0;
		while (index < read.length) {
			if (facts.printAnswer(read[index], this) != read[index + 1])
				return false;
			index += 2;
		}
		skippedFunctions++;
		return true;
	}

	public function forget(names:Map<String, Bool>):Void {
		for (name in [for (name in accepted.keys()) name])
			if (!names.exists(name))
				accepted.remove(name);
		for (name in [for (name in enumChecked.keys()) name])
			if (!names.exists(name))
				enumChecked.remove(name);
	}

	/** The answer each fact's print was made for, by fact. */
	final answers:Array<Dynamic> = [];

	override public function settle(id:Int, kind:Int, key:String, known:Bool):Bool {
		while (answers.length <= id)
			answers.push(null);
		var lookup = lookups[kind], before = answers[id], after:Dynamic = lookup == null ? null : lookup(key);
		answers[id] = after;
		return known && sameAnswer(kind, before, after);
	}

	/** Whether two answers of a table read the same to the verifier: its declarations part by part, its flags and names as values. */
	function sameAnswer(kind:Int, last:Dynamic, now:Dynamic):Bool {
		if (last == null || now == null)
			return last == now;
		return switch names[kind] {
			case "signatures":
				var before:{arguments:Array<IrType>, result:IrType, kind:IrFunctionKind} = last,
					after:{arguments:Array<IrType>, result:IrType, kind:IrFunctionKind} = now;
				IrDeclarationEquality.sameTypes(before.arguments, after.arguments)
					&& IrTypeIdentity.same(before.result, after.result)
					&& compiler.ir.codec.IrFunctionStateEquality.sameKind(before.kind, after.kind);
			case "objects": IrDeclarationEquality.sameObject(last, now);
			case "interfaces": IrDeclarationEquality.sameInterface(last, now);
			case "enums": IrDeclarationEquality.sameEnum(last, now);
			case "globals": IrTypeIdentity.same(last, now);
			case _: last == now;
		};
	}
}

/**
 * A program table as the function-level verifier sees it: `get` and `exists` only, noted in the memo when one is recording. The table
 * holds the map its reads go to, so a read costs the lookup in the program table and, for the first read of a key in a function, one
 * more in the reads; it never looks its own name up.
 */
class IrVerifyTable<V> {
	final read:String->Null<V>;
	final has:String->Bool;
	final name:String;
	final memo:Null<IrVerifyMemo>;
	final kind:Int;

	public function new(name:String, read:String->Null<V>, has:String->Bool, ?memo:IrVerifyMemo) {
		this.name = name;
		this.read = read;
		this.has = has;
		this.memo = memo;
		kind = memo == null ? -1 : memo.kindOf(name);
	}

	public function get(key:String):Null<V> {
		var value = read(key);
		if (memo != null && memo.recordingFunction)
			memo.note(kind, key);
		return value;
	}

	public function exists(key:String):Bool {
		var value = read(key);
		if (memo != null && memo.recordingFunction)
			memo.note(kind, key);
		return value != null || has(key);
	}
}
