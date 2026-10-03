// Control-flow shapes for the structured Wasm emitter; the expected values come from stock Haxe/HL.
function nested(limit:Int):Int {
	var total = 0;
	for (i in 0...limit) {
		if (i % 5 == 4)
			continue;
		for (j in 0...limit) {
			if (j > i)
				break;
			for (k in 0...3) {
				if ((i + j + k) % 7 == 0)
					continue;
				if (k == 2 && j == 3)
					break;
				total += i * 100 + j * 10 + k;
			}
			if (j == 6)
				continue;
			total += 1;
		}
		total += 1000;
	}
	return total;
}

function earlyReturn(limit:Int, target:Int):Int {
	var seen = 0;
	for (i in 0...limit) {
		for (j in 0...limit) {
			seen++;
			if (i * j == target)
				return seen * 1000 + i * 10 + j;
			if (i + j > limit + 2)
				break;
		}
	}
	return -seen;
}

function conditionLoop(start:Int):Int {
	var a = start, b = 0, steps = 0;
	while (a > 1 && b < 40 || steps < 3) {
		if (a % 2 == 0)
			a = a >> 1;
		else
			a = a * 3 + 1;
		b += a % 5;
		steps++;
		if (steps > 200)
			break;
	}
	return a * 1000 + b * 10 + steps;
}

function doWhileSkipping(limit:Int):Int {
	var i = 0, total = 0;
	do {
		i++;
		if (i % 3 != 0)
			total += i * i;
	} while (i < limit);
	return total;
}

function phiMerges(value:Int):Int {
	var x = 1, y = 2, z = 3;
	if (value > 10) {
		x = value;
		if (value > 20)
			y = value * 2;
		else
			z = value * 3;
	} else if (value > 5) {
		y = value + 100;
		z = x + y;
	} else {
		x = 0 - value;
	}
	var w = x + y * 2 + z * 3;
	if (w % 2 == 0)
		w += x;
	else
		w -= y;
	return w;
}

function loopAfterJoin(flag:Bool, limit:Int):Int {
	var counter = 0;
	if (flag)
		counter = 10;
	else
		counter = 20;
	var sum = 0;
	while (counter < limit) {
		sum += counter;
		counter += 3;
	}
	return sum * 10 + counter;
}

function selfLoop(seed:Int):Int {
	var value = seed, count = 0;
	while (true) {
		value = (value * 31 + 7) % 1000;
		count++;
		if (value % 10 == 3 || count >= 50)
			break;
	}
	return value * 100 + count;
}

function switchInLoop(limit:Int):Int {
	var total = 0;
	for (i in 0...limit) {
		switch (i % 4) {
			case 0:
				total += 1;
			case 1:
				if (i > 8)
					continue;
				total += 20;
			case 2:
				total += 300;
				if (total > 5000)
					break;
			default:
				total += 4000;
		}
		total += 5;
	}
	return total;
}

function deepNesting(n:Int):Int {
	var r = 0;
	for (a in 0...n) {
		if (a % 2 == 0) {
			for (b in 0...n) {
				if (b % 3 != 0) {
					var c = 0;
					while (c < n) {
						if (c == b)
							break;
						if ((a + b + c) % 4 == 1) {
							r += a;
							c += 2;
							continue;
						}
						r += c;
						c++;
					}
				} else {
					r -= 1;
				}
			}
		} else {
			r += 7;
		}
	}
	return r;
}

function loopInBranch(flag:Bool, limit:Int):Int {
	var total = 5;
	if (flag) {
		for (i in 0...limit)
			total += i;
	} else {
		var i = limit;
		while (i > 0) {
			total *= 2;
			i -= 3;
		}
	}
	return total + (flag ? 1 : 2);
}

function sequentialLoops(limit:Int):Int {
	var shared = 0;
	for (i in 0...limit)
		shared += i;
	for (j in 0...limit) {
		if (shared > 100)
			shared -= j;
		else
			shared += j * 2;
	}
	return shared;
}

function recursive(depth:Int):Int {
	if (depth <= 0)
		return 1;
	var total = 0;
	for (i in 0...3) {
		if (i == 1 && depth % 2 == 0)
			continue;
		total += recursive(depth - 1) + i;
	}
	return total;
}

function main():Int {
	var r = [
		nested(9),
		earlyReturn(8, 12),
		earlyReturn(6, 99),
		conditionLoop(27),
		conditionLoop(5),
		doWhileSkipping(20),
		phiMerges(25),
		phiMerges(15),
		phiMerges(7),
		phiMerges(2),
		loopAfterJoin(true, 50),
		loopAfterJoin(false, 12),
		selfLoop(7),
		selfLoop(123),
		switchInLoop(30),
		deepNesting(9),
		loopInBranch(true, 10),
		loopInBranch(false, 10),
		sequentialLoops(15),
		recursive(6)
	];
	var expected = [
		64802, 23026, -35, 182428, 1115, 2051, 159, 169, 432, 9, 4182, 20, 82308, 4310, 8988, 565, 51, 82, 102, 560
	];
	for (index in 0...expected.length)
		if (r[index] != expected[index])
			return index + 1;
	return 42;
}
