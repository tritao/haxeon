class Counter {
	public var value:Int = 0;

	public function new() {}
}

class State {
	public static var receivers:Int = 0;
	public static var indices:Int = 0;
	public static var counter:Counter = new Counter();
	public static var values:Array<Int> = [10];

	public static function receiver():Counter {
		receivers++;
		return counter;
	}

	public static function array():Array<Int> {
		receivers++;
		return values;
	}

	public static function index():Int {
		indices++;
		return 0;
	}
}

function main():Int {
	var assertions = 0;
	var actions = {run: () -> assertions += 21};
	if (actions.run() != 21 || actions.run() != 42 || assertions != 42)
		return 1;
	var field = {run: () -> State.receiver().value += 7};
	if (field.run() != 7 || State.counter.value != 7 || State.receivers != 1)
		return 2;
	var indexed = {run: () -> State.array()[State.index()] *= 3};
	if (indexed.run() != 30 || State.values[0] != 30 || State.receivers != 2 || State.indices != 1)
		return 3;
	var chained = {run: () -> assertions = State.counter.value += 2};
	if (chained.run() != 9 || assertions != 9 || State.counter.value != 9)
		return 4;
	return 42;
}
