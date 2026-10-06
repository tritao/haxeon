/** The ABI behind Reflect.compareMethods; this fixture also runs through the standalone frontend. */
@:hlNative("std", "fun_compare")
extern function compareMethods(left:Dynamic, right:Dynamic):Bool;

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
	if (!compareMethods(increment, increment))
		return 1;
	if (!compareMethods(instanceFunction, adder.add))
		return 2;
	if (compareMethods(adder.add, new WasmGcClosureAdder(40).add))
		return 3;
	if (compareMethods(instanceFunction, increment))
		return 4;
	if (!compareMethods(null, null) || compareMethods(instanceFunction, null))
		return 5;
	var callback = (value:Int) -> value + adder.value;
	if (!compareMethods(callback, callback) || compareMethods(callback, adder.add))
		return 6;
	return staticResult == 42 && instanceResult == 42 ? 42 : 0;
}
