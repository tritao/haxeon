package compiler.ir;

/**
 * One thing the verifier read about the rest of the program while it checked a function: the table, the key and the answer it got, kept
 * by reference. Whether a later answer is the same is decided by identity first and by the printed value only when identity differs.
 */
final class IrVerifyRead {
	public final table:String;
	public final key:String;
	public final value:Dynamic;

	public function new(table:String, key:String, value:Dynamic) {
		this.table = table;
		this.key = key;
		this.value = value;
	}
}

/**
 * What the last build's verification learned: the functions it accepted, with the reads each acceptance leaned on. A function is
 * verified again only when it is another function or when something it read gives another answer, so a build that changes a few
 * functions verifies those, and the functions that call them, and not the whole program.
 *
 * The verifier reads the program through `IrVerifyTable`s; every `get` and `exists` of a function's check is noted. A table has no
 * way to iterate, so a function-level check cannot read what it did not record.
 */
final class IrVerifyMemo {
	final accepted:Map<String, {fn:IrFunction, reads:Array<IrVerifyRead>}> = [];
	final tables:Map<String, String->Dynamic> = [];
	var printed:haxe.ds.ObjectMap<Dynamic, String> = new haxe.ds.ObjectMap();
	final current:Map<String, Map<String, IrVerifyRead>> = [];
	var recordingFunction = false;

	/** The functions whose inline-enum check passed, and what that check read besides the function (see `IrVerifier`). */
	public final enumChecked:Map<String, IrFunction> = [];

	public var enumContext = "";

	/** How many functions the last verification checked, and how many it took from the memo. */
	public var checkedFunctions = 0;

	public var skippedFunctions = 0;

	public function new() {}

	/** Starts a build: the tables the reads are answered from. */
	public function attach(named:Map<String, String->Dynamic>):Void {
		tables.clear();
		checkedFunctions = 0;
		skippedFunctions = 0;
		for (name => lookup in named)
			tables.set(name, lookup);
		printed = new haxe.ds.ObjectMap();
	}

	public function begin():Void {
		for (reads in current)
			reads.clear();
		recordingFunction = true;
	}

	/** Ends the check of `fn` and remembers what it read. */
	public function accept(fn:IrFunction):Void {
		checkedFunctions++;
		var reads:Array<IrVerifyRead> = [];
		for (table in current)
			for (read in table)
				reads.push(read);
		accepted.set(fn.name, {fn: fn, reads: reads});
		recordingFunction = false;
	}

	public function abandon():Void
		recordingFunction = false;

	/** Whether `fn` was accepted by an earlier build and everything it read still gives the same answer. */
	public function holds(fn:IrFunction):Bool {
		var known = accepted.get(fn.name);
		if (known == null || (known.fn != fn && !compiler.ir.codec.IrFunctionStateEquality.same(known.fn, fn)))
			return false;
		for (read in known.reads) {
			var lookup = tables.get(read.table);
			if (lookup == null)
				return false;
			var now = lookup(read.key);
			if (now == read.value)
				continue;
			if (print(read.value) != print(now))
				return false;
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

	/** Called by the tables of `IrVerifier` for every read made while a function is checked. */
	public function note(table:String, key:String, value:Dynamic):Void {
		if (!recordingFunction)
			return;
		var reads = current.get(table);
		if (reads == null) {
			reads = [];
			current.set(table, reads);
		}
		if (!reads.exists(key))
			reads.set(key, new IrVerifyRead(table, key, value));
	}

	/** The printed form of an answer, once per object per build: a signature read by a thousand callers is printed once. */
	function print(value:Dynamic):String {
		if (value == null)
			return "-";
		switch Type.typeof(value) {
			case TObject, TClass(_), TEnum(_):
			default:
				return Std.string(value);
		}
		var known = printed.get(value);
		if (known == null) {
			known = Std.string(value);
			printed.set(value, known);
		}
		return known;
	}
}
