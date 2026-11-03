import haxeon.Hashing;

struct LookupKey : Hashable {
	public var number:Int;
	public function new(number:Int) this.number = number;
}

class LookupOwner {
	public var number:Int;
	public function new(number:Int) this.number = number;
}

struct LookupValue {
	public var number:Int;
	public var owner:LookupOwner;
	public function new(number:Int, owner:LookupOwner) { this.number = number; this.owner = owner; }
}

class ValueLookup<K:Hashable, V> {
	final keys:Array<K>;
	final values:Array<V>;
	final hashes:Array<Int>;

	public function new(key:K, value:V) {
		keys = [key];
		values = [value];
		hashes = [Hashing.hash(key)];
	}

	function find(key:K):Int {
		var hash = Hashing.hash(key);
		return hashes[0] == hash && keys[0] == key ? 0 : -1;
	}

	public function get(key:K):Null<V> {
		var index = find(key);
		return index < 0 ? null : values[index];
	}

	public function required(key:K):V return values[find(key)];
	public function contains(key:K):Bool return find(key) >= 0;
}

class LookupCensus {
	static var values:ValueLookup<LookupKey, LookupValue>;
	static var owner:LookupOwner;
	static var noise:LookupOwner;
	public static function prepare():Void {
		owner = new LookupOwner(9);
		values = new ValueLookup<LookupKey, LookupValue>(new LookupKey(4), new LookupValue(7, owner));
	}
	public static function perform(n:Int):Int {
		var total = 0;
		for (_ in 0...n) {
			var value = values.get(new LookupKey(4));
			if (value == null || value.owner != owner || !values.contains(new LookupKey(4))) return -1;
			total += value.number + values.required(new LookupKey(4)).number;
		}
		return total;
	}
	static function useAfterAllocation(value:LookupValue):Int {
		noise = new LookupOwner(1);
		return value.owner.number;
	}
	public static function stress(n:Int):Int {
		var total = 0;
		for (_ in 0...n) total += useAfterAllocation(new LookupValue(7, new LookupOwner(9)));
		return total;
	}
}

function main():Int {
	LookupCensus.prepare();
	if (LookupCensus.perform(1) != 14) return 1;
	#if !wasm
	var before = hl.Gc.totalAllocated();
	var result = LookupCensus.perform(1024);
	var allocated = hl.Gc.totalAllocated() - before;
	if (result != 14336 || allocated != 0) {
		Sys.println('constrained lookup: result=$result allocated=$allocated bytes');
		return 2;
	}
	#end
	return 42;
}
