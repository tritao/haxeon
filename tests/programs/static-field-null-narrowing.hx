class Node {
	public var value:Int;
	public var count:Null<Int>;

	public function new(value:Int) {
		this.value = value;
	}
}

class Registry {
	public static var current:Null<Node>;
	public static var limit:Null<Int>;

	public static function clear():Void {
		current = null;
		limit = null;
	}

	public static function own():Int {
		if (limit != null && limit > 2)
			return limit + 1;
		return 0;
	}
}

function qualified():Int {
	if (Registry.current != null && Registry.current.value > 0)
		return Registry.current.value;
	return 0;
}

function earlyReturn():Int {
	if (Registry.current == null)
		return -1;
	return Registry.current.value * 2;
}

function arithmetic():Int {
	if (Registry.limit != null)
		return Registry.limit + 4;
	return 0;
}

function chained():Int {
	if (Registry.current != null && Registry.current.count != null)
		return Registry.current.count + 1;
	return 0;
}

function afterStore():Int {
	Registry.limit = 5;
	return Registry.limit * 2;
}

function afterClear():Int {
	if (Registry.current != null) {
		Registry.clear();
		return Registry.current == null ? 100 : 0;
	}
	return 0;
}

function main():Int {
	var total = qualified() + earlyReturn() + arithmetic() + chained() + Registry.own() + afterStore();
	Registry.current = new Node(3);
	Registry.limit = 3;
	Registry.current.count = 9;
	total += qualified() + earlyReturn() + arithmetic() + chained() + Registry.own() + afterStore();
	total += afterClear();
	return total - 107;
}
