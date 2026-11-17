// Haxe infers Tree<Int> from the first element and rejects Tree<Float> beside it: a constructor's inferred type
// parameters are fixed, not widened, by an array of constructors.
enum Tree<T> {
	Leaf(value:T);
	Empty;
}

class Main {
	static function main() {
		var numbers = [Leaf(1), Leaf(2.5)];
		trace(numbers.length);
	}
}
