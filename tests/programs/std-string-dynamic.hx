function main():Int {
	var negative = -42;
	var minimum:Int = -2147483647 - 1;
	var missing:Dynamic = null;
	if (Std.string(0) != "0" || Std.string(40) != "40" || Std.string(negative) != "-42" || Std.string(minimum) != "-2147483648")
		return 0;
	if (Std.string(true) != "true" || Std.string(false) != "false")
		return 0;
	if (Std.string(3.5) != "3.5" || Std.string(-3.5) != "-3.5" || Std.string(0.005) != "0.005" || Std.string(3.25) != "3.25")
		return 0;
	if (Std.string("ready") != "ready" || Std.string(missing) != "null")
		return 0;
	return 42;
}
