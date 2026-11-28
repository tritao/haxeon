import haxeon.Hashing;

// The hash helper of Key is requested by a generic specialization (LateBox<Key>.hash) and by a custom enum method typed after the
// ordinary bodies. Which of them asks first depends on what a session types, so a warm rebuild must not let it decide the helper's origin.
struct Key implements Hashable {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

class LateBox<T:Hashable> {
	var value:T;
	public function new(value:T) this.value = value;
	public function hash():Int return Hashing.hash(value);
}

enum Choice implements Equatable {
	Pick(value:Int);
	public function equals(other:Choice):Bool {
		var box = new LateBox<Key>(new Key(3));
		return box.hash() != 0 && switch other {
			case Pick(v): true;
		};
	}
}

function direct():Int return Hashing.hash(new Key(5)) != 0 ? 1 : 0;

function main():Int {
	return Pick(1).equals(Pick(2)) && direct() == 1 ? 42 : 1;
}
