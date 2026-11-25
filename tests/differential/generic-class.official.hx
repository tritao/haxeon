// A `@:generic` class is made once per type argument, as Haxe makes it: a column of `T`, a closure over `T`, `==` on `T`, and
// methods that override its base class's, with scalars, strings, objects and arrays as arguments.
class Item {
	public final name:String;

	public function new(name:String)
		this.name = name;
}

class Base {
	public function new() {}

	public function describe(index:Int):String
		return "base " + index;
}

@:generic
class Column<T> extends Base {
	final values:Array<T> = [];
	final same:(T, T) -> Bool;

	public function new(same:(T, T) -> Bool) {
		super();
		this.same = same;
	}

	/** The value kept at `index` when it is `value` or the same, else `value`, kept from now on. */
	public function put(index:Int, value:T):T {
		while (values.length <= index)
			values.push(value);
		var kept = values[index];
		if (kept == value || same(kept, value))
			return kept;
		values[index] = value;
		return value;
	}

	public function at(index:Int):T
		return values[index];

	override public function describe(index:Int):String
		return "column of " + values.length + " at " + index + ": " + values[index];
}

class Main {
	static function main() {
		var ints = new Column<Int>((a, b) -> a % 10 == b % 10);
		Sys.println(ints.put(0, 3) + " " + ints.put(0, 13) + " " + ints.put(0, 4) + " " + ints.at(0));
		var strings = new Column<String>((a, b) -> a.toLowerCase() == b.toLowerCase());
		Sys.println(strings.put(1, "a") + " " + strings.put(1, "A") + " " + strings.put(1, "b"));
		var first = new Item("x");
		var items = new Column<Item>((a, b) -> a.name == b.name);
		var kept = items.put(0, first);
		Sys.println((items.put(0, new Item("x")) == first) + " " + (items.put(0, new Item("y")) == first) + " "
			+ kept.name);
		var arrays = new Column<Array<Int>>((a, b) -> a.length == b.length);
		var list = [1, 2];
		Sys.println((arrays.put(0, [3, 4]) == list) + " " + arrays.at(0).length);
		var base:Base = ints;
		Sys.println(base.describe(0) + "; " + strings.describe(1) + "; " + new Base().describe(2));
	}
}
