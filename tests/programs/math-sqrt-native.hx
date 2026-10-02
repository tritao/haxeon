function main():Int {
	// Perfect squares are exact, as is zero.
	if (Math.sqrt(0.0) != 0.0
		|| Math.sqrt(1.0) != 1.0
		|| Math.sqrt(4.0) != 2.0
		|| Math.sqrt(144.0) != 12.0
		|| Math.sqrt(0.25) != 0.5)
		return 1;
	// Correctly rounded: the square of the root is within one rounding of the input.
	var two = Math.sqrt(2.0);
	if (two * two < 1.9999999999999996 || two * two > 2.0000000000000004 || two < 1.4142135623730951 || two > 1.4142135623730952)
		return 2;
	// Negative numbers and NaN give NaN; infinity stays infinity.
	var nan = Math.sqrt(-1.0);
	var infinity = 1.0 / 0.0;
	if (nan == nan || Math.sqrt(infinity) != infinity)
		return 3;
	// Used in a loop with a changing argument, the way distance computations use it.
	var sum = 0.0;
	for (i in 1...101)
		sum += Math.sqrt(i * i);
	if (sum != 5050.0)
		return 4;
	return 42;
}
