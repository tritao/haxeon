@:value
class Acc {
	public var count:Int;
	public var total:Int;
	public var flag:Bool;

	public function new() {}

	public function add(value:Int):Void {
		count = count + 1;
		total = total + value;
	}
}

@:value
class Point {
	public var x:Float;
	public var y:Float;

	public function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}

function keep(acc:Acc):Int {
	var total = 0;
	for (i in 0...3)
		total += acc.total * i + acc.count;
	return total;
}

function branches(flag:Bool):Int {
	var acc = new Acc();
	acc.add(10);
	if (flag)
		acc.add(5);
	else
		acc.flag = true;
	return acc.total + acc.count * 100 + (acc.flag ? 1000 : 0);
}

function loops(n:Int):Int {
	var acc = new Acc();
	for (i in 0...n)
		acc.add(i);
	return acc.total * 10 + acc.count;
}

function nested(n:Int):Int {
	var acc = new Acc();
	for (i in 0...n)
		for (j in 0...n)
			if ((i + j) % 2 == 0)
				acc.add(i * j);
	return acc.total + acc.count;
}

function earlyExit(limit:Int):Int {
	var acc = new Acc();
	for (i in 0...100) {
		if (acc.total > limit)
			break;
		acc.add(i);
	}
	return acc.count;
}

function conditionalWrite(flag:Bool):Int {
	var p = new Point(1.0, 2.0);
	if (flag)
		p.x = 10.0;
	return Std.int(p.x + p.y);
}

function readBeforeWrite(flag:Bool):Int {
	var acc = new Acc();
	if (flag)
		acc.total = 7;
	return acc.total + acc.count;
}

function escapesLate(n:Int):Int {
	var acc = new Acc();
	for (i in 0...n)
		acc.add(i);
	return keep(acc);
}

function perIteration(n:Int):Int {
	var t = 0;
	for (i in 0...n) {
		var acc = new Acc();
		acc.add(i);
		if (i % 2 == 0)
			acc.add(1);
		t += acc.total * 10 + acc.count;
	}
	return t;
}

function perIterationNested(n:Int):Int {
	var t = 0;
	for (i in 0...n) {
		var acc = new Acc();
		for (j in 0...3)
			acc.add(j + i);
		if (t > 1000)
			acc.flag = true;
		t += acc.total + acc.count + (acc.flag ? 1 : 0);
	}
	return t;
}

function main():Int {
	var failures = 0;
	if (branches(true) != 15 + 200)
		failures += 1;
	if (branches(false) != 10 + 100 + 1000)
		failures += 2;
	if (loops(5) != 10 * 10 + 5)
		failures += 4;
	// nested: pairs with i+j even, i,j in 0..3: (0,0)(0,2)(1,1)(2,0)(2,2) -> totals 0+0+1+0+4=5, count 5
	if (nested(3) != 5 + 5)
		failures += 8;
	if (earlyExit(20) != 7)
		failures += 16;
	if (conditionalWrite(true) != 12 || conditionalWrite(false) != 3)
		failures += 32;
	if (readBeforeWrite(true) != 7 || readBeforeWrite(false) != 0)
		failures += 64;
	if (escapesLate(4) != (6 * 0 + 4) + (6 * 1 + 4) + (6 * 2 + 4))
		failures += 128;
	if (loops(0) != 0)
		failures += 256;
	// i=0: total 0+1=1, count 2 -> 12; i=1: total 1, count 1 -> 11; i=2: total 2+1=3, count 2 -> 32; i=3: 3, 1 -> 31
	if (perIteration(4) != 12 + 11 + 32 + 31)
		failures += 512;
	// n=3: each i: adds j+i for j=0..2 -> total 3+3i, count 3 => t += 6+3i: 6, 9, 12 => 27
	if (perIterationNested(3) != 27)
		failures += 1024;
	return failures == 0 ? 42 : failures;
}
