class Counter {
	public static var calls:Int = 0;

	public static function part(text:String):String {
		calls++;
		return text;
	}
}

function main():Int {
	var failures = 0;
	var a = "alpha", b = "beta", n = -2147483648, m = 0, big = 2147483647, f = 12.5, g = 0.1 + 0.2;
	// Literals fold, operands keep their evaluation order, and every operand count works (1..12).
	if ("a" + "b" + "c" != "abc")
		failures += 1;
	if (a
		+ "|"
		+ b
		+ "|"
		+ a
		+ "|"
		+ b
		+ "|"
		+ a
		+ "|"
		+ b
		+ "|"
		+ a
		+ "|"
		+ b
		+ "|"
		+ a
		+ "|"
		+ b
		+ "|"
		+ a
		+ "|"
		+ b != "alpha|beta|alpha|beta|alpha|beta|alpha|beta|alpha|beta|alpha|beta")
		failures += 2;
	if ("n=" + n + "," + m + "," + big != "n=-2147483648,0,2147483647")
		failures += 4;
	if ("f=" + f + " g=" + g != "f=12.5 g=0.30000000000000004")
		failures += 8;
	var joined = Counter.part("x") + Counter.part("y") + Counter.part("z") + Counter.part("w");
	if (joined != "xyzw" || Counter.calls != 4)
		failures += 16;
	var empty = "";
	if (empty + empty + empty != "" || (empty + a + empty).length != 5)
		failures += 32;
	var s = "";
	for (i in 0...20)
		s += i + ",";
	if (s != "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,")
		failures += 64;
	if (Std.string(-7) + Std.string(1e21) + Std.string(0.5) != "-71e+210.5")
		failures += 128;
	return failures == 0 ? 42 : failures;
}
