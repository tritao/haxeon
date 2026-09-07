class Counter {
	public var value:Int = 41;

	public function new() {}

	public function callback():Void->Void
		return () -> this.value++;
}

function main():Int {
	var counter = new Counter();
	var callback = counter.callback();
	callback();
	return counter.value;
}
