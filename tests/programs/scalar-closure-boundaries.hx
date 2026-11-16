struct ClosureValue {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

function readValue(value:ClosureValue, offset:Int):Int return value.value + offset;

@:expose function callBoundary(callback:(ClosureValue, Int) -> Int):Int
	return callback(new ClosureValue(40), 2);

function main():Int {
	var callback:(ClosureValue, Int) -> Int = readValue;
	if (callBoundary(callback) != 42) return 1;
	var erased:Dynamic = callback;
	var restored:(ClosureValue, Int) -> Int = cast erased;
	return restored(new ClosureValue(40), 2);
}
