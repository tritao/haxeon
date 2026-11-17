// Unannotated functions typed for their signatures in their own type parameters: generic functions, a generic class's methods
// over an Array<T>, and an abstract's constructor and instance methods, of a generic abstract and of a plain one.
class Box<T> {
	var items:Array<T>;

	public function new()
		items = [];

	public function add(x) {
		items.push(x);
		return items.length;
	}

	public function last() return items[items.length - 1];
}

abstract Stack<T>(Array<T>) {
	public inline function new() this = [];

	public function push(value) {
		this.push(value);
		return this.length;
	}

	public function top() return this[this.length - 1];

	public function pairWith(other) return [top(), other];

	public function count() return this.length;
}

abstract Meters(Float) {
	public inline function new(value) this = value;

	public function doubled() return new Meters(this * 2);

	public function plus(other:Meters) return new Meters(this + other.value());

	public function value() return this;
}

class Main {
	static function firstOf<T>(values:Array<T>, fallback) return values.length > 0 ? values[0] : fallback;

	static function both<A, B>(a:A, b:B, label) return label + ":" + Std.string(a) + "/" + Std.string(b);

	static function main() {
		var stack = new Stack<String>();
		stack.push("a");
		Sys.println(stack.push("b") + " " + stack.top() + " " + stack.count());
		Sys.println(stack.pairWith("c"));
		var numbers = new Stack<Int>();
		numbers.push(4);
		Sys.println(numbers.top() * 2);
		var meters = new Meters(1.5).doubled();
		Sys.println(meters.plus(new Meters(0.5)).value());
		Sys.println(firstOf([3, 4], 0) + firstOf([], 7));
		Sys.println(firstOf(["x"], "y"));
		Sys.println(both(1, "two", "pair"));
		var box = new Box<String>();
		box.add("a");
		Sys.println(box.add("b") + box.last());
	}
}
