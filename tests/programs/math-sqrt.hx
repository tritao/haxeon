function negativeZero():Float {
	var zero = 0.0;
	return zero * -1.0;
}

function isNaN(value:Float):Bool
	return value != value;

function sumOfRoots(count:Int):Float {
	var total = 0.0;
	for (i in 0...count)
		total += Math.sqrt(i + 0.0);
	return total;
}

function main():Int {
	if (Math.sqrt(4.0) != 2.0 || Math.sqrt(2.25) != 1.5 || Math.sqrt(0.0) != 0.0 || Math.sqrt(1.0) != 1.0)
		return 1;

	// A negative operand and NaN give NaN; infinity stays infinity; the sign of zero is kept.
	if (!isNaN(Math.sqrt(-1.0)) || !isNaN(Math.sqrt(Math.NaN)) || !isNaN(Math.sqrt(Math.NEGATIVE_INFINITY)))
		return 2;
	if (Math.sqrt(Math.POSITIVE_INFINITY) != Math.POSITIVE_INFINITY)
		return 3;
	if (1 / Math.sqrt(negativeZero()) != Math.NEGATIVE_INFINITY || 1 / Math.sqrt(0.0) != Math.POSITIVE_INFINITY)
		return 4;

	// The result squares back to the operand within rounding, and sqrt is usable inside larger expressions.
	for (i in 0...200) {
		var root = Math.sqrt(i + 0.5);
		if (Math.abs(root * root - (i + 0.5)) > 1e-9)
			return 5;
	}
	var a = 3.0, b = 4.0;
	if (Math.sqrt(a * a + b * b) != 5.0 || Math.sqrt(a) * Math.sqrt(a) - a > 1e-12)
		return 6;

	// The sum 0 + 1 + 1.4142... + ... to 10000 terms, checked against the closed-form estimate 2/3 * n^1.5 - n^0.5 / 2.
	var estimate = 2.0 / 3.0 * Math.pow(10000.0, 1.5) - Math.sqrt(10000.0) / 2.0;
	if (Math.abs(sumOfRoots(10000) - estimate) > 1.0)
		return 7;
	return 42;
}
