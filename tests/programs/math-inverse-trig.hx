function near(actual:Float, expected:Float):Bool
	return Math.abs(actual - expected) <= 1.0e-15;

function main():Int {
	if (!near(Math.asin(0.0), 0.0) || !near(Math.asin(1.0), Math.PI / 2) || !near(Math.asin(-1.0), -Math.PI / 2))
		return 1;
	if (!near(Math.asin(0.5), Math.PI / 6) || !near(Math.sin(Math.asin(0.3)), 0.3))
		return 2;
	if (!Math.isNaN(Math.asin(1.5)))
		return 3;
	if (!near(Math.atan(1.0), Math.PI / 4) || !near(Math.atan(-1.0), -Math.PI / 4) || !near(Math.atan(0.0), 0.0))
		return 4;
	if (!near(Math.atan(Math.POSITIVE_INFINITY), Math.PI / 2) || !near(Math.tan(Math.atan(0.7)), 0.7))
		return 5;
	return 42;
}
