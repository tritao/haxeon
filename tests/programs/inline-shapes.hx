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

	public function scaled(factor:Int):Int {
		return sum() * factor;
	}
}

class Log {
	public static var trace:Int = 0;

	public static function tick(value:Int):Int {
		trace = trace * 10 + value;
		return value;
	}
}

inline function abs(value:Int):Int {
	return value < 0 ? -value : value;
}

function clamp(value:Int, low:Int, high:Int):Int {
	if (value < low)
		return low;
	if (value > high)
		return high;
	return value;
}

function sumTo(limit:Int):Int {
	var total = 0;
	for (i in 0...limit)
		total += i;
	return total;
}

function twice(value:Int):Int {
	return value + value;
}

function fourTimes(value:Int):Int {
	return twice(twice(value));
}

function fib(n:Int):Int {
	return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

function even(n:Int):Bool {
	return n == 0 ? true : odd(n - 1);
}

function odd(n:Int):Bool {
	return n == 0 ? false : even(n - 1);
}

function noResult(box:Array<Int>, value:Int):Void {
	box[0] = box[0] + value;
}

function pick(flag:Bool, first:Int, second:Int):Int {
	return flag ? first : second;
}

function main():Int {
	var failures = 0;
	if (abs(-5) != 5 || abs(7) != 7)
		failures += 1;
	if (clamp(-3, 0, 10) != 0 || clamp(4, 0, 10) != 4 || clamp(99, 0, 10) != 10)
		failures += 2;
	if (sumTo(5) != 10)
		failures += 4;
	if (fourTimes(3) != 12)
		failures += 8;
	if (fib(10) != 55)
		failures += 16;
	if (!even(10) || odd(10))
		failures += 32;
	var box = [1];
	for (i in 0...4)
		noResult(box, i);
	if (box[0] != 7)
		failures += 64;
	// Arguments are evaluated once, left to right, even when the callee reads its parameter several times.
	Log.trace = 0;
	var value = pick(Log.tick(1) > 0, Log.tick(2), Log.tick(3));
	if (value != 2 || Log.trace != 123)
		failures += 128;
	var pair = new Pair(3, 4);
	if (pair.sum() != 7 || pair.scaled(3) != 21)
		failures += 256;
	var accumulated = 0;
	for (i in 0...6)
		accumulated += clamp(i * 3, 2, 12) + abs(i - 3);
	// clamp: 2,3,6,9,12,12 = 44; abs: 3,2,1,0,1,2 = 9
	if (accumulated != 53)
		failures += 512;
	return failures == 0 ? 42 : failures;
}
