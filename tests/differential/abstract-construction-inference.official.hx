// A generic abstract's construction without type arguments infers them as Haxe does: from the arguments, or the expected type.
abstract Box<T>(Array<T>) {
	public function new(values:Array<T>)
		this = values;

	public static function of<T>(value:T):Box<T>
		return new Box([value]);

	public static function pair<T>(a:T, b:T):Box<T> {
		var box = of(a);
		box.add(b);
		return box;
	}

	public function add(value:T):Void
		this.push(value);

	public function first():T
		return this[0];

	public function size():Int
		return this.length;
}

class Main {
	static function main() {
		Sys.println(Box.of(3).size());
		Sys.println(Box.pair("a", "b").first());
		var strings = new Box(["x", "y"]);
		strings.add("z");
		Sys.println(strings.size() + " " + strings.first());
		var empty:Box<Int> = new Box([]);
		empty.add(7);
		Sys.println(empty.first() + 1);
	}
}
