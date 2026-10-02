class Box<T> {
	public var value(get, set):T;

	var stored:Null<T> = null;

	public function new() {}

	function get_value():T
		return stored;

	function set_value(value:T):T {
		stored = value;
		return value;
	}
}

class Counter {
	public var count:Int = 0;

	public function new() {}
}

function main():Int {
	var box = new Box<Counter>();
	box.value = new Counter();
	box.value.count++;
	return box.value.count == 1 ? 42 : 1;
}
