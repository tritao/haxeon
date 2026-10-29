// A generic class or interface instantiated with a concrete type is accepted where the same type with Dynamic is expected, as in Haxe.
class Box<T> {
	public var value:T;

	public function new(value:T)
		this.value = value;

	public function get():T
		return value;

	public function set(next:T):T
		return value = next;
}

class Item {
	public var n:Int;

	public function new(n:Int)
		this.n = n;
}

interface Source<T> {
	function next():T;
}

class Counter implements Source<Int> {
	var current:Int = 0;

	public function new() {}

	public function next():Int
		return ++current;
}

// Takes any box, whatever it holds.
function peek(box:Box<Dynamic>):Dynamic
	return box.get();

function drain(source:Source<Dynamic>):Int {
	var total = 0;
	for (_ in 0...3)
		total += cast(source.next(), Int);
	return total;
}

function main():Int {
	var items:Box<Item> = new Box(new Item(10));
	var numbers:Box<Int> = new Box(20);
	var failures = 0;

	// Reading through the Dynamic view sees the stored value.
	var viaDynamic:Box<Dynamic> = items;
	if (cast(peek(items), Item).n != 10)
		failures |= 1;
	if (cast(peek(numbers), Int) != 20)
		failures |= 2;

	// Writing through the Dynamic view is visible to the original.
	viaDynamic.set(new Item(11));
	if (items.get().n != 11)
		failures |= 4;
	var numbersView:Box<Dynamic> = numbers;
	numbersView.set(21);
	if (numbers.get() != 21)
		failures |= 8;

	// The same holds for a generic interface.
	if (drain(new Counter()) != 6)
		failures |= 16;

	// A value can be null through the view.
	var empty:Box<Item> = new Box<Item>(null);
	if (peek(empty) != null)
		failures |= 32;

	return failures == 0 ? 42 : failures;
}
