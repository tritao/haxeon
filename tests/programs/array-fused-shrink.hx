function shrinkInts(values:Array<Int>):Int {
	while (values.length > 1)
		values.pop();
	return 1;
}

function shrinkFloats(values:Array<Float>):Float {
	while (values.length > 1)
		values.pop();
	return 1.0;
}

function main():Int {
	var ints = [17, 25], intAlias = ints;
	var floats = [17.5, 24.5], floatAlias = floats;
	var total = ints[1], live = floats[1];
	shrinkInts(intAlias);
	shrinkFloats(floatAlias);
	var caught = 0;
	try {
		#if eval
		if (1 >= ints.length)
			throw "Array index out of bounds";
		#end
		total += ints[1];
	} catch (_:Dynamic) {
		total += ints[0];
		caught++;
	}
	try {
		#if eval
		if (1 >= floats.length)
			throw "Array index out of bounds";
		#end
		live += floats[1];
	} catch (_:Dynamic) {
		live += floats[0];
		caught++;
	}
	if (total != 42 || live != 42.0 || caught != 2)
		return 1;
	// Preserve the existing HL compound-write rule: validation survives a shrinking callee.
	// Capacity does not shrink, so this write stays in allocated storage without restoring logical length.
	var small = [1, 2, 3];
	var position = small.length - 1;
	small[position] += shrinkInts(small);
	if (small[0] != 1)
		return 2;
	#if (eval || wasm)
	if (small.length != 3)
		return 3;
	#else
	if (small.length != 1)
		return 3;
	#end
	return 42;
}
