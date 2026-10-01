// Operators with a Dynamic operand are decided by what the values are when the program runs: two Ints give an Int,
// anything else a Float, `+` with a String joins, and the result is Dynamic.
function main():Int {
	var whole:Dynamic = {n: 7};
	var half:Dynamic = {n: 2.5};
	var text:Dynamic = {n: "x"};
	var a:Dynamic = whole.n;
	var b:Dynamic = half.n;
	var s:Dynamic = text.n;
	var sum = a + 3;
	var floatSum = a + b;
	var difference = a - 2;
	var product = a * a;
	var quotient = a / 2;
	var joined = s + a;
	var bits = (a & 3) | 8;
	var shifted = (a << 2) >> 1;
	var xor = a ^ 5;
	var unsigned = a >>> 1;
	var negated = -a;
	var negatedFloat = -b;
	var asInt:Int = sum;
	var asFloat:Float = floatSum;
	var typed:Int = Std.int(a * 2);
	var checks = [
		asInt == 10,
		asFloat == 9.5,
		difference == 5,
		product == 49,
		quotient == 3.5,
		joined == "x7",
		bits == 11,
		shifted == 14,
		xor == 2,
		unsigned == 3,
		negated == -7,
		negatedFloat == -2.5,
		typed == 14,
		a < 8,
		!(a < 7),
		a <= 7,
		b<a, a>
		b,
		a >= 7,
		!(a > 7),
		s < "y",
		!(s < 3)
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
