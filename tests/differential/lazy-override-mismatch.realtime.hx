class Base {
	public function new() {}

	public function value():Null<Int> return 1;
}

class Derived extends Base {
	public function new() {
		super();
	}

	override public function value() return 2;
}

class Main {
	static function main() {
		Sys.println(new Derived().value());
	}
}
