// A generic abstract over a structure of its type parameters, `abstract Pair<A, B>({first:A, second:B})`: its methods read the
// structure's fields whatever the type arguments are, scalars or references.
class Item {
	public var name:String;

	public function new(name:String)
		this.name = name;
}

abstract Pair<A, B>({first: A, second: B}) {
	public inline function new(first:A, second:B)
		this = {first: first, second: second};

	public var first(get, never):A;
	public var second(get, never):B;

	function get_first():A
		return this.first;

	function get_second():B
		return this.second;

	public function swap():Pair<B, A>
		return new Pair(this.second, this.first);

	public function withSecond<C>(value:C):Pair<A, C>
		return new Pair(this.first, value);

	public function describe():String
		return "(" + this.first + ", " + this.second + ")";
}

abstract Cell<T>({value: T}) {
	public function new(value:T)
		this = {value: value};

	public function get():T
		return this.value;

	public function set(value:T):Void
		this.value = value;
}

class Main {
	static function firstOf<A, B>(pair:Pair<A, B>):A
		return pair.first;

	static function main() {
		var p = new Pair<Int, String>(1, "a");
		Sys.println(p.first + " " + p.second);
		var q = new Pair(2.5, true);
		Sys.println(q.first + " " + q.second);
		var s = p.swap();
		Sys.println(s.first + " " + s.second);
		Sys.println(p.withSecond(new Item("x")).second.name);
		Sys.println(p.describe() + " " + q.describe() + " " + s.describe());
		Sys.println(firstOf(p) + " " + firstOf(new Pair("k", 3)));
		var nested = new Pair(new Pair(1, 2), [3, 4]);
		Sys.println(nested.first.second + " " + nested.second.length);
		var cell = new Cell("one");
		cell.set("two");
		var numbers = new Cell(5);
		numbers.set(numbers.get() + 1);
		Sys.println(cell.get() + " " + numbers.get());
	}
}
