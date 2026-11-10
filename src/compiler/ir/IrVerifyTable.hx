package compiler.ir;

/** A program table as the function-level verifier sees it: `get` and `exists` only, noted in the memo when one is recording. */
class IrVerifyTable<V> {
	final read:String->Null<V>;
	final has:String->Bool;
	final name:String;
	final memo:Null<IrVerifyMemo>;

	public function new(name:String, read:String->Null<V>, has:String->Bool, ?memo:IrVerifyMemo) {
		this.name = name;
		this.read = read;
		this.has = has;
		this.memo = memo;
	}

	public function get(key:String):Null<V> {
		var value = read(key);
		if (memo != null)
			memo.note(name, key, value);
		return value;
	}

	public function exists(key:String):Bool {
		if (memo != null)
			memo.note(name, key, read(key));
		return has(key);
	}
}
