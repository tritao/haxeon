function main():Int {
	// for, while and do-while loops with and without break/continue, nested.
	var found = -1;
	for (i in 0...10) {
		if (i == 4) {
			found = i;
			break;
		}
	}
	var skipped = 0;
	for (i in 0...6) {
		if (i % 2 == 0)
			continue;
		skipped += i;
	}
	var nested = 0;
	for (i in 0...4)
		for (j in 0...4) {
			if (j == 2)
				break;
			nested += 1;
		}
	var count = 0;
	var n = 0;
	while (n < 5) {
		n++;
		if (n == 4)
			break;
		count++;
	}
	var plain = 0;
	while (plain < 3)
		plain++;
	var spins = 0;
	do {
		spins++;
	} while (spins < 3);
	if (found != 4 || skipped != 9 || nested != 8 || count != 3 || plain != 3 || spins != 3)
		return 1;

	// Int and Float arrays: in-range reads, growth by writing past the end, and read-modify-write.
	var ints = [1, 2, 3];
	var floats = [0.5, 1.5];
	ints[3] = 4;
	floats[2] = 2.5;
	for (i in 0...ints.length)
		ints[i] += 10;
	for (i in 0...floats.length)
		floats[i] *= 2.0;
	if (ints.length != 4 || ints[0] != 11 || ints[3] != 14 || floats.length != 3 || floats[0] != 1.0 || floats[2] != 5.0)
		return 2;

	// Out-of-range access raises instead of reading or writing outside the array.
	var raised = 0;
	var past = ints.length;
	var negative = -1;
	try {
		var value = ints[past];
		raised += value;
	} catch (error:Dynamic) {
		raised += 1;
	}
	try {
		var value = floats[negative];
		raised += Std.int(value);
	} catch (error:Dynamic) {
		raised += 10;
	}
	try {
		ints[negative] = 7;
		raised += 100;
	} catch (error:Dynamic) {
		raised += 100;
	}
	if (raised != 111 || ints.length != 4)
		return 3;
	return 42;
}
