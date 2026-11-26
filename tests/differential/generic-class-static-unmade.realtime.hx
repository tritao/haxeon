// A static of a `@:generic` class that no code makes for an argument compiles, as in Haxe: the class is rejected only where it is
// first made for its arguments.
@:generic
class Box<T> {
	public var value:T;

	public function new(value:T)
		this.value = value;

	public static function one():Int
		return 1;
}

class Main {
	static function main() {
		Sys.println(Box.one());
	}
}
