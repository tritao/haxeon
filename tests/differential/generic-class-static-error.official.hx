// Each instance of a `@:generic` class is a class of its own, so Haxe rejects a static field on one, at the field.
@:generic
class Box<T> {
	public static var made = 0;
	public var value:T;

	public function new(value:T) {
		this.value = value;
		made++;
	}
}

class Main {
	static function main() {
		new Box<Int>(1);
		new Box<String>("x");
		Sys.println(Box.made);
	}
}
