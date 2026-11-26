// A static method on a `@:generic` class is rejected as a static variable is, once the class is made for an argument.
@:generic
class Box<T> {
	public var value:T;

	public function new(value:T)
		this.value = value;

	public static function one():Int return 1;
}

class Main {
	static function main() {
		Sys.println(Box.one() + new Box<Int>(2).value);
	}
}
