class Counter {
	public var value:Int = 41;

	public function new() {}

	public function callback():Void->Void
		return () -> this.value++;

	public function setter():Void->Void
		return () -> value = 42;
}

function main():Int {
	var counter = new Counter();
	var callback = counter.callback();
	callback();
	var setter = counter.setter();
	setter();
	return counter.value;
}
