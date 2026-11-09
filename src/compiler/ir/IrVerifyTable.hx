package compiler.ir;

/** A program table as the function-level verifier sees it: `get` and `exists` only, noted in the memo when one is recording. */
final class IrVerifyTable<V> {
	final inner:Map<String, V>;
	final name:String;
	final memo:Null<IrVerifyMemo>;

	public function new(name:String, inner:Map<String, V>, ?memo:IrVerifyMemo) {
		this.name = name;
		this.inner = inner;
		this.memo = memo;
	}

	public function get(key:String):Null<V> {
		var value = inner.get(key);
		if (memo != null)
			memo.note(name, key, value);
		return value;
	}

	public function exists(key:String):Bool {
		if (memo != null)
			memo.note(name, key, inner.get(key));
		return inner.exists(key);
	}
}
