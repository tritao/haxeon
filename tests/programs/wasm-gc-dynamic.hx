interface WasmGcDynamicAdder {
	function add(value:Int):Int;
}

class WasmGcDynamicConcrete implements WasmGcDynamicAdder {
	public function new() {}

	public function add(value:Int):Int {
		return value + 1;
	}
}

class WasmGcDynamicOverride extends WasmGcDynamicConcrete {
	public function new() {
		super();
	}

	override public function add(value:Int):Int {
		return value + 2;
	}
}

function main():Int {
	var number:Dynamic = 40,
		sameNumber:Dynamic = 40,
		otherNumber:Dynamic = 41,
		recoveredNumber:Int = cast(number, Int),
		flag:Dynamic = true,
		recoveredFlag:Bool = cast(flag, Bool),
		floatValue:Dynamic = 1.5,
		recoveredFloat:Float = cast(floatValue, Float),
		nanValue:Dynamic = 0.0 / 0.0,
		original:Dynamic = new WasmGcDynamicConcrete(),
		concrete:WasmGcDynamicConcrete = cast(original, WasmGcDynamicConcrete),
		adder:WasmGcDynamicAdder = cast(original, WasmGcDynamicAdder),
		derived:Dynamic = new WasmGcDynamicOverride(),
		overridden:WasmGcDynamicAdder = cast(derived, WasmGcDynamicAdder),
		nullValue:Dynamic = null,
		nullAdder:WasmGcDynamicAdder = cast(nullValue, WasmGcDynamicAdder);
	return number == sameNumber && number != otherNumber && recoveredNumber == 40 && recoveredFlag && recoveredFloat == 1.5 && !(nanValue == nanValue)
		&& concrete != null && nullAdder == null && adder.add(41) == 42 && overridden.add(40) == 42 ? 42 : 0;
}
