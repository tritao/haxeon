function near(actual:Float, expected:Float):Bool
	return Math.abs(actual - expected) <= 1.0e-12 * Math.max(1.0, Math.abs(expected));

function main():Int {
	if (!near(Math.exp(0.0), 1.0) || !near(Math.exp(1.0), 2.718281828459045) || !near(Math.exp(-2.0), 0.1353352832366127))
		return 1;
	if (!near(Math.log(1.0), 0.0) || !near(Math.log(2.718281828459045), 1.0) || !near(Math.log(Math.exp(3.5)), 3.5))
		return 2;
	if (Math.log(0.0) != Math.NEGATIVE_INFINITY || !Math.isNaN(Math.log(-1.0)))
		return 3;
	if (Math.exp(Math.NEGATIVE_INFINITY) != 0.0 || Math.exp(1000.0) != Math.POSITIVE_INFINITY)
		return 4;
	return 42;
}
