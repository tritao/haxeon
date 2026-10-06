import haxe.ds.ObjectMap;

class IdentityKey {
	public var value:Int;

	public function new(value:Int)
		this.value = value;
}

function main():Int {
	var map = new ObjectMap<IdentityKey, Int>();
	var first = new IdentityKey(1), second = new IdentityKey(1);
	map.set(first, 10);
	map.set(second, 20);
	if (map.get(first) != 10 || map.get(second) != 20)
		return 1;
	first.value = 2;
	map.set(first, 42);
	if (map.get(first) != 42 || !map.exists(second))
		return 2;
	if (!map.remove(first) || map.exists(first) || map.remove(first))
		return 3;
	if (map.get(first) != null || map.get(second) != 20)
		return 4;
	return 42;
}
