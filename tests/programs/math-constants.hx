function main():Int {
	var positive = Math.POSITIVE_INFINITY;
	var negative = Math.NEGATIVE_INFINITY;
	var nan = Math.NaN;
	if (Math.isFinite(positive) || Math.isNaN(positive) || positive <= 1.0e308)
		return 1;
	if (Math.isFinite(negative) || Math.isNaN(negative) || negative >= -1.0e308)
		return 2;
	if (positive != -negative || positive != 1.0 / 0.0)
		return 3;
	if (!Math.isNaN(nan) || nan == nan)
		return 4;
	if (Math.min(positive, 5.0) != 5.0 || Math.max(negative, -5.0) != -5.0)
		return 5;
	return 42;
}
