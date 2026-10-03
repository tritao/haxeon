// Functions that throw but contain no try are emitted structured, in a module that also has handlers. Expected values come from stock Haxe/HL.
function riskyLoop(n:Int):Int {
	var total = 0;
	for (i in 0...n) {
		if (i == 7)
			throw "seven";
		total += i;
	}
	return total;
}

function throwsAfterNested(a:Int):Int {
	var total = 0;
	for (i in 0...a) {
		for (j in 0...a) {
			if (i * j == 12)
				throw i * 100 + j;
			total += j;
		}
	}
	return total;
}

function guarded(n:Int):Int {
	try {
		return riskyLoop(n);
	} catch (error:Dynamic) {
		return -1;
	}
}

function guardedValue(a:Int):Int {
	try {
		return throwsAfterNested(a);
	} catch (code:Int) {
		return code;
	}
}

function guardedInLoop(n:Int):Int {
	var caught = 0, sum = 0;
	for (i in 0...n) {
		try {
			sum += riskyLoop(i);
		} catch (error:Dynamic) {
			caught++;
		}
	}
	return sum * 100 + caught;
}

function cleanup(n:Int):Int {
	var steps = 0;
	try {
		for (i in 0...n) {
			steps++;
			if (steps > 3)
				riskyLoop(20);
		}
	} catch (error:Dynamic) {
		steps += 1000;
	}
	return steps;
}

function main():Int {
	var r = [
		guarded(5),
		guarded(9),
		guardedValue(5),
		guardedValue(3),
		guardedInLoop(10),
		cleanup(3),
		cleanup(8)
	];
	var expected = [10, -1, 304, 9, 5602, 3, 1004];
	for (index in 0...expected.length)
		if (r[index] != expected[index])
			return index + 1;
	return 42;
}
