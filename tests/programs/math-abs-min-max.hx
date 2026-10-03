function negativeZero():Float {
	var zero = 0.0;
	return zero * -1.0;
}

function isNaN(value:Float):Bool
	return value != value;

function main():Int {
	// abs clears the sign of zero and leaves NaN alone.
	if (1 / Math.abs(negativeZero()) != Math.POSITIVE_INFINITY || 1 / Math.abs(0.0) != Math.POSITIVE_INFINITY)
		return 1;
	if (Math.abs(-2.5) != 2.5
		|| Math.abs(2.5) != 2.5
		|| Math.abs(Math.NEGATIVE_INFINITY) != Math.POSITIVE_INFINITY
		|| !isNaN(Math.abs(Math.NaN)))
		return 2;
	if (Math.abs(-1e-320) != 1e-320 || Math.abs(-1.7976931348623157e308) != 1.7976931348623157e308)
		return 3;

	// min and max with a NaN operand are NaN, whichever side it is on.
	var nan = Math.NaN;
	if (!isNaN(Math.min(nan, 1.0)) || !isNaN(Math.min(1.0, nan)) || !isNaN(Math.max(nan, 1.0)) || !isNaN(Math.max(1.0, nan)))
		return 4;
	if (!isNaN(Math.min(nan, nan))
		|| !isNaN(Math.max(nan, nan))
		|| !isNaN(Math.min(nan, Math.NEGATIVE_INFINITY))
		|| !isNaN(Math.max(Math.POSITIVE_INFINITY, nan)))
		return 5;

	// Ordinary operands.
	if (Math.min(1.0, 2.0) != 1.0 || Math.min(2.0, 1.0) != 1.0 || Math.max(1.0, 2.0) != 2.0 || Math.max(2.0, 1.0) != 2.0)
		return 6;
	if (Math.min(-3.0, 3.0) != -3.0 || Math.max(-3.0, 3.0) != 3.0 || Math.min(4.0, 4.0) != 4.0 || Math.max(4.0, 4.0) != 4.0)
		return 7;
	if (Math.min(Math.NEGATIVE_INFINITY, 5.0) != Math.NEGATIVE_INFINITY
		|| Math.max(Math.POSITIVE_INFINITY, 5.0) != Math.POSITIVE_INFINITY
		|| Math.min(Math.POSITIVE_INFINITY, 5.0) != 5.0
		|| Math.max(Math.NEGATIVE_INFINITY, 5.0) != 5.0)
		return 8;

	// A running fold, as a loop would take them.
	var low = Math.POSITIVE_INFINITY, high = Math.NEGATIVE_INFINITY, total = 0.0;
	for (i in 0...1000) {
		var value = ((i * 7919) % 1009) - 500.0;
		low = Math.min(low, value);
		high = Math.max(high, value);
		total += Math.abs(value);
	}
	if (low != -500.0 || high != 508.0 || total != 252304.0)
		return 9;
	return 42;
}
