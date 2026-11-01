/** The ABI behind Reflect.compareMethods; this fixture also runs through the standalone frontend. */
@:hlNative("std", "fun_compare")
extern function compareMethods(left:Dynamic, right:Dynamic):Bool;

@:hlNative("std", "make_var_args")
extern function makeVarargs(callback:Array<Dynamic>->Dynamic):Dynamic;

class WasmGcVarargsCheck {
	public static var observed:Int = 0;
	public static function booleanArgument(value:Int, enabled:Bool):Void
		observed = enabled ? value : -1;
}

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

function returnsTwo(value:Int):Int return 2;

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
	// Bool and Int share a Wasm i32 representation, but a varargs adapter must box the requested type.
	var booleanClosure:(Int, Bool)->Void = WasmGcVarargsCheck.booleanArgument;
	var dynamicVarargs:Dynamic = makeVarargs(arguments -> {
		var argument:Int = arguments[1];
		WasmGcVarargsCheck.observed = argument;
		return null;
	});
	var integerClosure:(Int, Int)->Void = cast dynamicVarargs;
	integerClosure(1, 42);
	if (WasmGcVarargsCheck.observed != 42) return 7;
	var boolVarargs:Dynamic = makeVarargs(arguments -> {
		var enabled:Bool = arguments[1];
		WasmGcVarargsCheck.observed = enabled ? 9 : -9;
		return null;
	});
	var boolAdapter:(Int, Bool)->Void = cast boolVarargs;
	boolAdapter(1, true);
	if (WasmGcVarargsCheck.observed != 9) return 9;
	var typedSource:Dynamic = booleanClosure;
	var integerView:(Int, Int)->Void = cast typedSource;
	if (compareMethods(booleanClosure, integerView)) return 10;
	integerView(8, 2);
	if (WasmGcVarargsCheck.observed != 8) return 11;
	var dynamicResult:Dynamic = returnsTwo;
	var boolResult:Int->Bool = cast dynamicResult;
	if (!boolResult(0)) return 12;
	booleanClosure(8, true);
	if (WasmGcVarargsCheck.observed != 8) return 8;
	return staticResult == 42 && instanceResult == 42 ? 42 : 0;
}
