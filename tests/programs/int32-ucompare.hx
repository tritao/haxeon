// haxe.Int32.ucompare compares as unsigned 32-bit integers, as Haxe's does.
function main():Int {
	if (haxe.Int32.ucompare(1, 2) >= 0 || haxe.Int32.ucompare(2, 1) <= 0 || haxe.Int32.ucompare(5, 5) != 0)
		return 1;
	// -1 is 0xFFFFFFFF: above every non-negative Int when unsigned.
	if (haxe.Int32.ucompare(-1, 0x7FFFFFFF) <= 0 || haxe.Int32.ucompare(0, -2147483648) >= 0
		|| haxe.Int32.ucompare(-2, -1) >= 0)
		return 2;
	return 42;
}
