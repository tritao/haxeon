// A method of a Dynamic value is looked up by name when the program runs and called with Dynamic arguments; what it
// returns is Dynamic.
class Counter {
	public var total:Int = 0;

	public function new() {}

	public function add(amount:Int):Int {
		total = total + amount;
		return total;
	}

	public function reset():Void {
		total = 0;
	}

	public function describe(prefix:String, count:Int):String
		return prefix + count;

	public function scaled(factor:Float):Float
		return total * factor;
}

function main():Int {
	var counter:Dynamic = new Counter();
	var first:Int = counter.add(5);
	var second:Int = counter.add(7);
	var text:String = counter.describe("n=", 3);
	var scaled:Float = counter.scaled(0.5);
	counter.reset();
	var afterReset:Int = counter.total;
	var holder:Dynamic = {inner: new Counter()};
	var viaNested:Int = holder.inner.add(4);
	var handlers:Dynamic = {double: (value:Int) -> value * 2};
	var viaFunctionField:Int = handlers.double(21);
	var checks = [
		first == 5,
		second == 12,
		text == "n=3",
		scaled == 6.0,
		afterReset == 0,
		viaNested == 4,
		viaFunctionField == 42
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
