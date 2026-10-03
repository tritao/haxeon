function sameBits(a:Float, b:Float):Bool {
	if (a != a)
		return b != b;
	if (a == 0.0 && b == 0.0)
		return 1.0 / a == 1.0 / b;
	return a == b;
}

function divideBy2(x:Float):Float {
	return x / 2.0;
}

function divideByHalf(x:Float):Float {
	return x / 0.5;
}

function divideBy1024(x:Float):Float {
	return x / 1024.0;
}

function divideByNegative4(x:Float):Float {
	return x / -4.0;
}

function divideByMinNormal(x:Float):Float {
	return x / 2.2250738585072014e-308;
}

function divideBy3(x:Float):Float {
	return x / 3.0;
}

function check(actual:Float, x:Float, divisor:Float):Bool {
	var expected = x / divisor;
	return expected != expected ? actual != actual : sameBits(actual, expected);
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
	// Array loads keep the reference divisors opaque to strength reduction.
	var divisors = [2.0, 0.5, 1024.0, -4.0, 2.2250738585072014e-308, 3.0];
	for (value in inputs) {
		if (!check(divideBy2(value), value, divisors[0]))
			return 1;
		if (!check(divideByHalf(value), value, divisors[1]))
			return 2;
		if (!check(divideBy1024(value), value, divisors[2]))
			return 3;
		if (!check(divideByNegative4(value), value, divisors[3]))
			return 4;
		if (!check(divideByMinNormal(value), value, divisors[4]))
			return 5;
	}
	// 5 / 3 differs from 5 * (1 / 3) by one ULP; keep the numerator opaque too.
	var nonPowerInputs = [5.0];
	if (!check(divideBy3(nonPowerInputs[0]), nonPowerInputs[0], divisors[5]))
		return 7;
	// These constants are deliberately outside the rewrite set.
	if (9.0 / 3.0 != 3.0 || 100.0 / 10.0 != 10.0 || 1.0 / 8.98846567431158e307 == 0.0)
		return 6;
	return 42;
}
