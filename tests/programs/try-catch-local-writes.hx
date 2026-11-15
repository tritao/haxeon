// A local assigned inside `try` is seen by `catch` with its latest value, whatever path reached the `try`: a value merged
// from two branches, a loop-carried value, or nested trys each keep the write.
function thrower(fail:Bool):Int {
	if (fail)
		throw "fail";
	return 0;
}

function merged(cond:Bool):Int {
	var x = 0;
	if (cond)
		x = 1;
	else
		x = 2;
	try {
		x = 10;
		thrower(true);
		x = 20;
	} catch (e:Dynamic) {
		return x;
	}
	return -1;
}

function nested(cond:Bool):Int {
	var x = cond ? 1 : 2;
	try {
		x = 3;
		try {
			x = 4;
			thrower(true);
		} catch (e:Dynamic) {
			x += 10;
			thrower(true);
		}
	} catch (e:Dynamic) {
		return x;
	}
	return -1;
}

function looped(n:Int):Int {
	var total = 0;
	for (i in 0...n) {
		try {
			total += i;
			thrower(i == n - 1);
		} catch (e:Dynamic) {
			return total;
		}
	}
	return -1;
}

function untouchedBefore(cond:Bool):Int {
	var y:Int;
	if (cond)
		y = 5;
	else
		y = 6;
	var z = y;
	try {
		z = y * 2;
		thrower(true);
	} catch (e:Dynamic) {
		return z;
	}
	return -1;
}

function main():Int {
	if (merged(true) != 10 || merged(false) != 10)
		return 1;
	if (nested(true) != 14 || nested(false) != 14)
		return 2;
	if (looped(4) != 6)
		return 3;
	if (untouchedBefore(true) != 10 || untouchedBefore(false) != 12)
		return 4;
	return 42;
}
