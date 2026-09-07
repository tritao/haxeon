class Counter {
	public var value:Int = 40;

	public function new() {}

	function addTwo():Void
		value = value + 2;

	public function callback():Void->Void
		return () -> addTwo();
}


function wrap(operation:Int->Int):Void->Int
	return () -> operation(40);

function main():Int {
	var counter = new Counter();
	var callback = counter.callback();
	callback();
	var wrapped = wrap(value -> value + 2);
	return counter.value == 42 ? wrapped() : 0;
}
