// Std.parseInt follows C strtol with base detection; Std.parseFloat follows strtod.
function main():Int {
	if (Std.parseInt("42") != 42 || Std.parseInt(" -12x") != -12 || Std.parseInt("0x1F") != 31 || Std.parseInt("010") != 8)
		return 1;
	if (Std.parseInt("") != 0 || Std.parseInt("abc") != 0 || Std.parseInt("+7") != 7)
		return 2;
	if (Std.parseFloat("1.25") != 1.25 || Std.parseFloat("-3.5e2") != -350 || Std.parseFloat("  2.5E-3") != 0.0025)
		return 3;
	if (Std.parseFloat(".5") != 0.5 || Std.parseFloat("7.") != 7 || Std.parseFloat("12px") != 12)
		return 4;
	if (!Math.isNaN(Std.parseFloat("abc")) || !Math.isNaN(Std.parseFloat("")) || Std.parseFloat("-inf") != Math.NEGATIVE_INFINITY)
		return 5;
	return 42;
}
