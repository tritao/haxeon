// A Float converted to Int by a cast: in range it rounds toward zero; out of range, NaN included, it is what the VM's
// conversion gives on this machine, which the C of an ahead-of-time build must give too (tests/aot/programs.txt).
function truncate(value:Float):Int {
	var result:Int = cast value;
	return result;
}

function main():Int {
	if (truncate(1.5) != 1 || truncate(-1.5) != -1 || truncate(2147483647.0) != 2147483647
		|| truncate(-2147483648.0) != -2147483648)
		return 1;
	for (value in [
		2147483648.0,
		-2147483649.0,
		3e9,
		-3e9,
		1e20,
		-1e20,
		Math.POSITIVE_INFINITY,
		Math.NEGATIVE_INFINITY,
		Math.NaN
	])
		Sys.println(truncate(value));
	return 42;
}
