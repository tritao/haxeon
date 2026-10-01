// `%` with a Dynamic operand is a Float, as in Haxe: the remainder of two Ints is exact, and a Float operand gives a
// Float remainder.
function main():Int {
	var whole:Dynamic = {n: 7};
	var half:Dynamic = {n: 2.5};
	var a:Dynamic = whole.n;
	var b:Dynamic = half.n;
	var remainder = a % 4;
	var floatRemainder = b % 2;
	var mixed = a % b;
	var checks = [remainder == 3, floatRemainder == 0.5, mixed == 2.0];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
