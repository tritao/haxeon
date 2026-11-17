// An abstract's properties are its accessors, as in Haxe: a read calls get_x and a write set_x, also from the abstract's own
// methods, through +=, ++ and type parameters.
abstract Stack(Array<Int>) from Array<Int> {
	public var length(get, never):Int;
	public var top(get, set):Int;
	var secret(get, never):Int;

	inline function get_length():Int
		return this.length;

	function get_top():Int
		return this[this.length - 1];

	function set_top(value:Int):Int {
		this[this.length - 1] = value;
		return value;
	}

	function get_secret()
		return 42;

	public function describe():String {
		top = top + 1;
		return length + ":" + top + ":" + secret;
	}
}

abstract Box<T>(Array<T>) from Array<T> {
	public var first(get, never):T;

	function get_first():T
		return this[0];
}

class Main {
	static function main() {
		var stack:Stack = [1, 2, 3];
		Sys.println(stack.length);
		Sys.println(stack.top);
		stack.top = 10;
		Sys.println(stack.top);
		stack.top += 5;
		Sys.println(stack.top);
		Sys.println(stack.top++);
		Sys.println(stack.top);
		Sys.println(stack.describe());
		var box:Box<String> = ["abc"];
		Sys.println(box.first.length);
	}
}
