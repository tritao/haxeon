// Eval establishes the checksums. An indirect returning call stays visible even with the inliner enabled.
function clobber(seed:Int):Int {
	var a = seed * 0.125;
	var b = a + 0.25;
	var c = b + 0.5;
	var d = c + 1.0;
	var e = d + 2.0;
	var f = e + 4.0;
	return Std.int(a + b + c + d + e + f);
}

function accumulate(count:Int, call:Int->Int):Float {
	var sum = 0.0;
	for (i in 0...count) {
		if ((i & 31) == 0)
			sum += call(i) * 0.125;
		sum += (i & 7) * 0.125;
	}
	return sum;
}

function exceptional(call:Int->Int):Float {
	var sum = 0.0;
	try {
		for (i in 0...100) {
			sum += 0.125;
			if (i == 63)
				call(i);
		}
	} catch (error:Dynamic) {
		return sum;
	}
	return -1.0;
}

function main():Int {
	if (accumulate(1000, clobber) != 1981.5)
		return 1;
	if (exceptional(function(i:Int):Int {
		throw "expected";
	}) != 8.0)
		return 2;
	return 42;
}
