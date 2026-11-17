class Counter {
	var count = 0;

	public function new() {}

	public function step() return ++count;

	public function adder() return (x:Int) -> x + count;

	public function snapshot() return {count: count, label: "counter"};
}

class Main {
	static function pair(a:Int, b:String) return {first: a, second: b};

	static function scale(factor:Float) return (x:Float) -> x * factor;

	static function main() {
		var p = pair(3, "three");
		Sys.println(p.first + 1);
		Sys.println(p.second.length);
		var triple = scale(3);
		Sys.println(triple(1.5));
		var c = new Counter();
		c.step();
		c.step();
		Sys.println(c.adder()(10));
		var s = c.snapshot();
		Sys.println(s.label + ":" + s.count);
	}
}
