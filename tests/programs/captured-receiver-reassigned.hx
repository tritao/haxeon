class Box {
	public var v:Int;

	public function new(v:Int) {
		this.v = v;
	}

	public function plus(other:Box):Box {
		return new Box(v + other.v);
	}

	public function get():Int {
		return v;
	}

	// Too large to inline.
	public function weigh(scale:Int):Int {
		var total = 0;
		for (index in 0...scale)
			total += v + index;
		if (total > 1000000)
			total = 1000000;
		return total;
	}
}

// A closure that only calls a method on a captured local must see the local's current value, not the one it started with.
function main():Int {
	var results:Array<Bool> = [];
	// 1. A method call on a reassigned captured local, after an unconditional reassignment.
	var a = new Box(1);
	a = new Box(2);
	function plusTen()
		return a.plus(new Box(10)).v;
	results.push(plusTen() == 12);
	// 2. Reassigned again after the closure exists: each call sees the latest value.
	a = new Box(5);
	results.push(plusTen() == 15);
	// 3. A reassignment under a condition.
	var b = new Box(1);
	if (results.length > 0)
		b = new Box(20);
	function readB()
		return b.get();
	results.push(readB() == 20);
	// 4. An anonymous function.
	var c = new Box(3);
	c = new Box(4);
	var viaLambda = () -> c.get();
	results.push(viaLambda() == 4);
	// 5. A method too big to inline.
	var d = new Box(7);
	d = new Box(9);
	var heavy = () -> d.weigh(3);
	results.push(heavy() == 30);
	// 6. A field read, which already worked, and the same call outside any closure.
	var e = new Box(1);
	e = new Box(6);
	var field = () -> e.v;
	results.push(field() == 6 && e.get() == 6);
	// 7. The closure reassigns the local and the caller then calls a method on it.
	var f = new Box(1);
	var swap = () -> {
		f = new Box(8);
		return 0;
	};
	swap();
	results.push(f.get() == 8);
	// 8. A closure inside a closure.
	var g = new Box(2);
	g = new Box(3);
	var outer = () -> {
		var inner = () -> g.get();
		return inner();
	};
	results.push(outer() == 3);
	for (index in 0...results.length)
		if (!results[index])
			return index + 1;
	return 42;
}
