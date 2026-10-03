function conditional(count:Int):Float {
	var sum = 0.0;
	for (i in 0...count) {
		if ((i & 1) == 0)
			sum += 0.125;
		else
			sum += 0.25;
	}
	return sum;
}

function oldValue(count:Int):Int {
	var value = 0, checksum = 0;
	for (i in 0...count) {
		var before = value;
		value += 1;
		checksum += before * 2 + value;
	}
	return checksum;
}

function oldFloatValue(count:Int):Float {
	var value = 0.0, checksum = 0.0;
	for (i in 0...count) {
		var before = value;
		value += 1.0;
		checksum += before * 2.0 + value;
	}
	return checksum;
}

function earlyExit():Float {
	var value = 0.0;
	while (value < 8.0) {
		var next = value + 1.0;
		if (next == 4.0)
			return value;
		value = next;
	}
	return -1.0;
}

function nested():Float {
	var value = 1.0, sum = 0.0;
	for (i in 0...8) {
		for (j in 0...4)
			sum += value;
		value += 0.125;
	}
	return sum;
}

function main():Int {
	if (conditional(8) != 1.5)
		return 1;
	if (oldValue(8) != 92)
		return 2;
	if (earlyExit() != 3.0)
		return 3;
	if (nested() != 46.0)
		return 4;
	if (oldFloatValue(8) != 92.0)
		return 5;
	return 42;
}
