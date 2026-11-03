struct MapKey : Hashable {
	public var number:Int;
	public function new(number:Int) this.number = number;
	public function hash():Int return 1;
	public function equals(other:MapKey):Bool return number == other.number;
}

struct ChurnKey : Hashable {
	public var number:Int;
	public function new(number:Int) this.number = number;
	public function hash():Int return number;
	public function equals(other:ChurnKey):Bool return number == other.number;
}

class MapOwner {
	public var number:Int;
	public function new(number:Int) this.number = number;
}

struct MapValue {
	public var number:Int;
	public var owner:MapOwner;
	public function new(number:Int, owner:MapOwner) { this.number = number; this.owner = owner; }
}

enum MapEnumKey { First; Second; }

class MapCensus {
	static var owner:MapOwner;
	static var both:Map<MapKey, MapValue>;
	static var values:Map<Int, MapValue>;
	static var keys:Map<MapKey, Int>;
	static var optional:Map<Int, Null<MapValue>>;
	public static function prepare():Void {
		owner = new MapOwner(9);
		both = new Map(); both.set(new MapKey(4), new MapValue(7, owner));
		values = new Map(); values.set(4, new MapValue(7, owner));
		keys = new Map(); keys.set(new MapKey(4), 7);
		optional = new Map(); optional.set(4, new MapValue(7, owner));
	}
	public static function perform(n:Int):Int {
		var total = 0;
		for (_ in 0...n) {
			both.set(new MapKey(4), new MapValue(7, owner));
			values.set(4, new MapValue(7, owner));
			keys.set(new MapKey(4), 7);
			optional.set(4, new MapValue(7, owner));
			var a = both.get(new MapKey(4)), b = values.get(4), c = optional.get(4);
			if (a == null || b == null || c == null || !keys.exists(new MapKey(4)) || a.owner != owner || b.owner != owner || c.owner != owner) return -1;
			total += a.number + b.number + c.number + 7;
		}
		return total;
	}
	public static function grow(n:Int):Int {
		var both:Map<MapKey, MapValue> = new Map();
		var values:Map<Int, MapValue> = new Map();
		var keys:Map<MapKey, Int> = new Map();
		for (index in 0...n) {
			both.set(new MapKey(index), new MapValue(index, owner));
			values.set(index, new MapValue(index, owner));
			keys.set(new MapKey(index), index);
		}
		var a = both.get(new MapKey(n - 1)), b = values.get(n - 1);
		return a != null && b != null && a.number == n - 1 && b.number == n - 1 && a.owner == owner && b.owner == owner
			&& keys.exists(new MapKey(n - 1)) ? 42 : 1;
	}
}

function main():Int {
	var owner = new MapOwner(3), map:Map<MapKey, MapValue> = new Map();
	for (index in 0...100) map.set(new MapKey(index), new MapValue(index * 2, owner));
	for (index in 0...100) {
		var value = map.get(new MapKey(index));
		if (value == null || value.number != index * 2 || value.owner != owner) return 1;
	}
	var copyValue = map.get(new MapKey(1));
	if (copyValue == null) return 2;
	copyValue.number = 99;
	var original = map.get(new MapKey(1));
	if (original == null || original.number != 2) return 3;
	for (index in 0...50) if (!map.remove(new MapKey(index * 2))) return 4;
	for (index in 0...50) map.set(new MapKey(100 + index), new MapValue(index, owner));
	var copy = map.copy(), seen = 0;
	for (key in copy.keys()) { if (!copy.exists(key)) return 5; seen++; }
	if (seen != 100) return 6;
	map.clear();
	if (map.exists(new MapKey(1)) || !copy.exists(new MapKey(1))) return 7;
	var byEnum:Map<MapEnumKey, MapValue> = new Map();
	byEnum.set(First, new MapValue(11, owner)); byEnum.set(Second, new MapValue(12, owner));
	var enumTotal = 0;
	for (key in byEnum.keys()) {
		var value = byEnum.get(key);
		if (value == null) return 8;
		enumTotal += value.number;
	}
	if (enumTotal != 23) return 8;
	var optional:Map<Int, Null<MapValue>> = new Map();
	optional.set(1, null);
	optional.set(2, new MapValue(42, owner));
	var optionalValue = optional.get(2);
	if (!optional.exists(1) || optional.get(1) != null || optionalValue == null || optionalValue.number != 42 || optionalValue.owner != owner) return 12;
	var optionalKey:Map<Null<MapKey>, MapValue> = new Map();
	optionalKey.set(null, new MapValue(5, owner));
	optionalKey.set(new MapKey(1), new MapValue(6, owner));
	var nullKeyValue = optionalKey.get(null), presentKeyValue = optionalKey.get(new MapKey(1));
	if (nullKeyValue == null || presentKeyValue == null || nullKeyValue.number != 5 || presentKeyValue.number != 6) return 13;
	var churn:Map<ChurnKey, MapValue> = new Map();
	for (index in 0...1024) {
		var key = new ChurnKey(index);
		churn.set(key, new MapValue(index, owner));
		var value = churn.get(key);
		if (value == null || value.number != index || !churn.remove(key) || churn.exists(key)) return 11;
	}
	MapCensus.prepare();
	if (MapCensus.perform(1) != 28) return 9;
	#if !wasm
	var before = hl.Gc.totalAllocated(), result = MapCensus.perform(1024), allocated = hl.Gc.totalAllocated() - before;
	if (result != 28672 || allocated != 0) {
		Sys.println('specialized map: result=$result allocated=$allocated bytes');
		return 10;
	}
	#end
	return 42;
}
