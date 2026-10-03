function main():Int {
	// Expected floor/ceil pairs from stock Haxe --interp; all conversions stay in range.
	var inputs:Array<Float> = [
		-2.0000001,
		-2.0,
		-1.9999999,
		-0.0000001,
		-0.0,
		0.0,
		0.0000001,
		1.9999999,
		2.0,
		2.0000001,
		2147483646.75,
		-2147483646.75
	];
	var floors:Array<Int> = [-3, -2, -2, -1, 0, 0, 0, 1, 2, 2, 2147483646, -2147483647];
	var ceils:Array<Int> = [-2, -2, -1, 0, 0, 0, 1, 2, 2, 3, 2147483647, -2147483646];
	var total = 0;
	for (i in 0...inputs.length) {
		var value = inputs[i];
		if (Math.floor(value) != floors[i])
			return 1;
		if (Math.ceil(value) != ceils[i])
			return 2;
		total += Math.floor(value) + Math.ceil(value);
	}
	if (total != 0)
		return 3;
	// Non-finite rounding uses the Float API: converting these to Int is not portable.
	var nan = Math.NaN;
	if (Math.ffloor(nan) == Math.ffloor(nan) || Math.fceil(nan) == Math.fceil(nan))
		return 4;
	if (Math.ffloor(Math.POSITIVE_INFINITY) != Math.POSITIVE_INFINITY || Math.fceil(Math.NEGATIVE_INFINITY) != Math.NEGATIVE_INFINITY)
		return 5;
	var zero = 0.0 * -1.0;
	if (1.0 / Math.ffloor(zero) != Math.NEGATIVE_INFINITY || 1.0 / Math.fceil(zero) != Math.NEGATIVE_INFINITY)
		return 6;
	return 42;
}
