function sameBits(a:Float, b:Float):Bool {
	if (a != a)
		return b != b;
	if (a == 0.0 && b == 0.0)
		return 1.0 / a == 1.0 / b;
	return a == b;
}

function check(x:Float, divisor:Float, reciprocal:Float):Bool {
	var divided = x / divisor, multiplied = x * reciprocal;
	return divided != divided ? multiplied != multiplied : sameBits(divided, multiplied);
}

function main():Int {
	var inputs = [
		0.0,
		-0.0,
		5e-324,
		-5e-324,
		1.5,
		-17.25,
		1.7976931348623157e308,
		Math.POSITIVE_INFINITY,
		Math.NEGATIVE_INFINITY,
		Math.NaN
	];
	for (value in inputs) {
		if (!check(value, 2.0, 0.5))
			return 1;
		if (!check(value, 0.5, 2.0))
			return 2;
		if (!check(value, 1024.0, 0.0009765625))
			return 3;
		if (!check(value, -4.0, -0.25))
			return 4;
		if (!check(value, 2.2250738585072014e-308, 4.49423283715579e307))
			return 5;
	}
	// These constants are deliberately outside the rewrite set.
	if (9.0 / 3.0 != 3.0 || 100.0 / 10.0 != 10.0 || 1.0 / 8.98846567431158e307 == 0.0)
		return 6;
	return 42;
}
