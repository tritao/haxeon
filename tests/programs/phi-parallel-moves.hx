// The values that flow into a loop's next iteration are assigned at once: a swap or a rotation reads every old value before it
// writes a new one, however the moves on the edge are ordered.
@:noInline function swaps(count:Int):Int {
	var a = 1, b = 2;
	for (_ in 0...count) {
		var t = a;
		a = b;
		b = t;
	}
	return a * 10 + b;
}

@:noInline function rotation(count:Int):Int {
	var a = 1, b = 2, c = 3;
	for (_ in 0...count) {
		var t = a;
		a = b;
		b = c;
		c = t;
	}
	return a * 100 + b * 10 + c;
}

@:noInline function fibonacci(count:Int):Int {
	var previous = 0, current = 1;
	for (_ in 0...count) {
		var next = previous + current;
		previous = current;
		current = next;
	}
	return previous;
}

@:noInline function chain(count:Int):Float {
	var x = 1.0, y = 2.0, flag = true;
	for (_ in 0...count) {
		var oldX = x;
		x = y;
		y = oldX + y;
		flag = !flag;
	}
	return flag ? x : -x;
}

function main():Int {
	var checks = [
		swaps(0) == 12 && swaps(1) == 21 && swaps(2) == 12 && swaps(3) == 21,
		rotation(1) == 231 && rotation(2) == 312 && rotation(3) == 123,
		fibonacci(10) == 55 && fibonacci(1) == 1,
		chain(3) == -5.0 && chain(2) == 3.0
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return 100 + index;
	return 42;
}
