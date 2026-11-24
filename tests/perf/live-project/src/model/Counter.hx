package model;

class Counter {
	public var total = 0;

	public function new() {}

	public function step():Void
		total += increment();

	function increment():Int
		return 1;
}
