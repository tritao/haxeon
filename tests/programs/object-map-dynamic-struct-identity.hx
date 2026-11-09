import haxe.ds.ObjectMap;

struct IdentityValue {
	public var value:Int;

	public function new(value:Int)
		this.value = value;
}

function main():Int {
	var first:Dynamic = cast new IdentityValue(7),
		sameBox:Dynamic = first,
		distinctBox:Dynamic = cast new IdentityValue(7),
		map = new ObjectMap<Dynamic, Int>();
	map.set(first, 42);
	if (!map.exists(sameBox) || map.get(sameBox) != 42 || map.exists(distinctBox))
		return 1;
	map.set(distinctBox, 21);
	if (map.get(first) != 42 || map.get(distinctBox) != 21)
		return 2;
	if (!map.remove(sameBox) || map.exists(first) || !map.exists(distinctBox))
		return 3;
	return 42;
}
