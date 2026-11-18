// `(value : Type)` never downcasts, as Haxe's type check does not ("Base should be Derived"); `cast` does.
class Base {
	public function new() {}
}

class Derived extends Base {}

class Main {
	static function main() {
		var derived = (new Base():Derived);
		Sys.println(derived);
	}
}
