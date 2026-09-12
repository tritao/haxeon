class WasmGcClosureAdder {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}

	public function add(delta:Int):Int {
		return value + delta;
	}
}

function increment(value:Int):Int {
	return value + 1;
}

function main():Int {
	var staticFunction:Int->Int = increment,
		staticResult = staticFunction(41),
		adder = new WasmGcClosureAdder(40),
		instanceFunction:Int->Int = adder.add,
		instanceResult = instanceFunction(2);
	return staticResult == 42 && instanceResult == 42 ? 42 : 0;
}
