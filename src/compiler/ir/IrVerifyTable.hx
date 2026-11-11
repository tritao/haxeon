package compiler.ir;

import compiler.ir.IrVerifyMemo.IrVerifyRead;

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
	final reads:Null<Map<String, IrVerifyRead>>;

	public function new(name:String, read:String->Null<V>, has:String->Bool, ?memo:IrVerifyMemo) {
		this.name = name;
		this.read = read;
		this.has = has;
		this.memo = memo;
		reads = memo == null ? null : memo.readsOf(name);
	}

	public function get(key:String):Null<V> {
		var value = read(key);
		if (memo != null && memo.recordingFunction)
			note(key, value);
		return value;
	}

	public function exists(key:String):Bool {
		var value = read(key);
		if (memo != null && memo.recordingFunction)
			note(key, value);
		return value != null || has(key);
	}

	function note(key:String, value:Dynamic):Void
		if (reads.get(key) == null)
			reads.set(key, new IrVerifyRead(name, key, value));
}
