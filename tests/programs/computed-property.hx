class Counter {
	var stored:Int;

	public var value(get, set):Int;

	public function new(value:Int) {
		stored = value;
	}

	function get_value():Int
		return stored;

	function set_value(value:Int):Int {
		stored = value;
		return value;
	}

	public function increment():Void
		value = value + 1;
}

class Main {
	static function main():Int {
		var counter = new Counter(41);
		counter.increment();
		return counter.value;
	}
}
