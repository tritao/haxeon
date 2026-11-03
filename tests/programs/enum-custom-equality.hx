import haxeon.Hashing;

enum Key<T> : Hashable {
	Item(value:T);

	public function equals(other:Key<T>):Bool {
		return true;
	}

	public function hash():Int {
		return 7;
	}
}

enum Outer : Equatable {
	Wrap(key:Key<Int>);
}

function main():Int {
	var first:Key<Int> = Item(1), second:Key<Int> = Item(2);
	if (!(first == second) || !first.equals(second)) return 1;
	if (first.hash() != 7 || Hashing.hash(second) != 7) return 2;
	if (Type.enumEq(first, second)) return 3;
	var values:Map<Key<Int>, Int> = [];
	values.set(first, 42);
	if (values.get(second) != 42 || ![first].contains(second)) return 4;
	var left:Outer = Wrap(first), right:Outer = Wrap(second);
	if (!(left == right) || Type.enumEq(left, right)) return 5;
	return 42;
}
