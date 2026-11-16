// Std.parseInt as Haxe's: null without digits, decimal unless "0x", leading spaces and a sign, trailing text ignored.
function main():Int {
	if (Std.parseInt("x") != null || Std.parseInt("") != null || Std.parseInt("-") != null || Std.parseInt(" ") != null)
		return 1;
	if (Std.parseInt("12abc") != 12 || Std.parseInt("  7") != 7 || Std.parseInt("-3") != -3 || Std.parseInt("+4") != 4)
		return 2;
	if (Std.parseInt("010") != 10 || Std.parseInt("0x1F") != 31 || Std.parseInt("0X10") != 16
		|| Std.parseInt("0x") != 0)
		return 3;
	return 42;
}
