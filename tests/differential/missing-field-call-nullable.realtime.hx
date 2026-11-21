// A nullable receiver's missing method names its type as declared, Null<> included, as Haxe reports it.
class Box<T> {
	public var value:T;

	public function new(value:T)
		this.value = value;
}

class Main {
	static function main() {
		var box:Null<Box<Int>> = new Box(1);
		box.missing();
	}
}
