class Counter {
	public static var value:Int;

	public static function set(next:Int):Void {
		Counter.value = next;
	}

	public static function get():Int {
		return Counter.value;
	}
}

function main():Int {
	Counter.value = 40;
	Counter.set(Counter.value + 1);
	return Counter.get() + Counter.value - 1;
}
