// A call of a method the class does not have is reported as a missing field, at its name, as Haxe reports it.
class Counter {
	public function new() {}

	public function count():Int
		return 1;
}

class Main {
	static function main() {
		var counter = new Counter();
		counter.reset();
	}
}
