function same(actual:Float, expected:Float):Bool
	return actual == expected || (actual != actual && expected != expected);

function main():Int {
	var large = 3000000000.5;
	var huge = 9007199254740993.0;
	var cases:Array<Array<Float>> = [
		// value, ffloor, fceil, fround
		[2.5, 2.0, 3.0, 3.0],
		[-2.5, -3.0, -2.0, -2.0],
		[-0.4, -1.0, -0.0, -0.0],
		[7.0, 7.0, 7.0, 7.0],
		[large, 3000000000.0, 3000000001.0, 3000000001.0],
		[-large, -3000000001.0, -3000000000.0, -3000000000.0],
		[huge, huge, huge, huge],
		[0.49999999999999994, 0.0, 1.0, 0.0],
	];
	for (index in 0...cases.length) {
		var entry = cases[index];
		if (!same(Math.ffloor(entry[0]), entry[1]) || !same(Math.fceil(entry[0]), entry[2]) || !same(Math.fround(entry[0]), entry[3]))
			return index + 1;
	}
	var nan = Math.sqrt(-1.0), infinity = 1.0 / 0.0;
	if (!same(Math.ffloor(nan), nan) || Math.fceil(infinity) != infinity || Math.fround(-infinity) != -infinity)
		return 20;
	return 42;
}
