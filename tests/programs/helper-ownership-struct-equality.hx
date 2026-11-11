import haxeon.Hashing;

// The equality helper of Pair is requested by an `==` in one function and by a map key (equality and hash) in another.
struct Pair implements Hashable {
	public var left:Int;
	public var right:Int;
	public function new(left:Int, right:Int) {
		this.left = left;
		this.right = right;
	}
}

function equal(a:Pair, b:Pair):Bool return a == b;

function keyed():Int {
	var map:Map<Pair, Int> = new Map();
	map.set(new Pair(1, 2), 5);
	return map.exists(new Pair(1, 2)) && !map.exists(new Pair(2, 1)) ? 5 : 0;
}

function main():Int {
	return equal(new Pair(3, 4), new Pair(3, 4)) && !equal(new Pair(3, 4), new Pair(4, 3)) && keyed() == 5 ? 42 : 1;
}
