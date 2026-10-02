// break and continue in do-while: break skips the condition, continue evaluates it. Expected values come from stock Haxe/HL.
function firstOver(limit:Int):Int {
	var i = 0;
	do {
		i += 3;
		if (i > limit)
			break;
	} while (true);
	return i;
}

function skipping(limit:Int):Int {
	var i = 0, total = 0;
	do {
		i++;
		if (i % 3 == 0)
			continue;
		total += i * i;
	} while (i < limit);
	return total;
}

class Counter {
	public static var checks:Int = 0;
}

function countedCondition(value:Int):Bool {
	Counter.checks++;
	return value < 100;
}

function breakSkipsCondition():Int {
	Counter.checks = 0;
	var counter = 0;
	do {
		counter++;
		if (counter == 3)
			break;
	} while (countedCondition(counter));
	return counter * 100 + Counter.checks;
}

function continueRunsCondition():Int {
	Counter.checks = 0;
	var counter = 0;
	do {
		counter++;
		if (counter < 4)
			continue;
		counter += 10;
	} while (countedCondition(counter));
	return counter * 100 + Counter.checks;
}

function nestedMix(n:Int):Int {
	var r = 0, a = 0;
	do {
		a++;
		var b = 0;
		do {
			b++;
			if (b == 2)
				continue;
			if (b > a + 1)
				break;
			r += a * 10 + b;
		} while (b < n);
		for (c in 0...n) {
			if (c == a)
				break;
			r += c;
		}
		if (a % 2 == 0)
			continue;
		r += 1000;
	} while (a < n);
	return r;
}

function assignedInBody():Int {
	var x:Int;
	do {
		x = 5;
	} while (false);
	return x + 1;
}

function onePass():Int {
	var count = 0;
	do {
		count++;
		if (count == 1)
			continue;
		count += 100;
	} while (false);
	return count;
}

function main():Int {
	var r = [
		firstOver(10),
		firstOver(2),
		skipping(10),
		skipping(1),
		breakSkipsCondition(),
		continueRunsCondition(),
		nestedMix(5),
		nestedMix(2),
		assignedInBody(),
		onePass()
	];
	var expected = [12, 3, 259, 1, 302, 10212, 3559, 1033, 6, 1];
	for (index in 0...expected.length)
		if (r[index] != expected[index])
			return index + 1;
	return 42;
}
