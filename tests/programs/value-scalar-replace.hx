@:value
class Pair {
	public var a:Int;
	public var b:Int;

	public function new(a:Int, b:Int) {
		this.a = a;
		this.b = b;
	}

	public function sum():Int {
		return a + b;
	}

	public function swapped():Pair {
		return new Pair(b, a);
	}
}

@:value
class Cell {
	public var value:Float;
	public var flag:Bool;
	public var count:Int;

	public function new() {}

	public function bump():Void {
		count = count + 1;
	}
}

class Holder {
	public var pair:Pair;

	public function new() {
		pair = new Pair(0, 0);
	}
}

function consume(pair:Pair):Int {
	// Big enough that it is not inlined, so the argument escapes into a call.
	var total = 0;
	for (i in 0...4)
		total += pair.a * i + pair.b;
	return total;
}

function makePair(a:Int, b:Int):Pair {
	return new Pair(a, b);
}

function main():Int {
	var failures = 0;
	// Never leaves the block: constructor, field reads and a method are all inlined and the allocation disappears.
	var local = 0;
	for (i in 0...5) {
		var p = new Pair(i, 3);
		local += p.sum();
	}
	if (local != 10 + 15)
		failures += 1;
	// Fields read before any write take their zero value.
	var cell = new Cell();
	if (cell.value != 0.0 || cell.flag || cell.count != 0)
		failures += 2;
	cell.bump();
	cell.bump();
	if (cell.count != 2)
		failures += 4;
	// Two objects interleaved.
	var first = new Pair(1, 2), second = new Pair(10, 20);
	if (first.sum() + second.sum() != 33)
		failures += 8;
	// Escapes: passed to a call, returned, stored in a field, kept in an array.
	if (consume(new Pair(2, 5)) != 2 * 6 + 20)
		failures += 16;
	var made = makePair(4, 6);
	if (made.sum() != 10 || made.swapped().a != 6)
		failures += 32;
	var holder = new Holder();
	holder.pair = new Pair(7, 8);
	if (holder.pair.sum() != 15)
		failures += 64;
	var list:Array<Pair> = [];
	for (i in 0...3)
		list.push(new Pair(i, i));
	var listed = 0;
	for (item in list)
		listed += item.sum();
	if (listed != 6)
		failures += 128;
	// A write that follows a read keeps program order.
	var order = new Pair(1, 1);
	var before = order.a;
	order.a = 5;
	if (before != 1 || order.a != 5 || order.sum() != 6)
		failures += 256;
	return failures == 0 ? 42 : failures;
}
