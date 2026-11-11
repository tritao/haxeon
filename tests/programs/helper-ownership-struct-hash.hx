import haxeon.Hashing;

// One hash helper for Key, requested by two functions written in the opposite order to the order a warm session retypes them.
struct Key implements Hashable {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

function viaMap():Int {
	var map:Map<Key, Int> = new Map();
	map.set(new Key(1), 10);
	map.set(new Key(2), 20);
	return map.get(new Key(2)) == 20 && map.size() == 2 ? 22 : 0;
}

function viaHashing():Int {
	return Hashing.hash(new Key(7)) == Hashing.hash(new Key(7)) ? 20 : 0;
}

function main():Int {
	return viaMap() == 22 && viaHashing() == 20 ? 42 : 1;
}
