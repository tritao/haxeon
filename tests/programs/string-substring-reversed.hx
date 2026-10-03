function main():Int {
	var text = "hello";
	// A reversed pair swaps after both indexes clamp into the string, as in Haxe.
	var a = 4;
	var b = 1;
	if (text.substring(a, b) != "ell")
		return 1;
	if (text.substring(-2, 3) != "hel" || text.substring(3, -1) != "hel" || text.substring(2, -5) != "he")
		return 2;
	if (text.substring(2, 100) != "llo" || text.substring(100, 2) != "llo")
		return 3;
	if (text.substring(5, 5) != ""
		|| text.substring(-3, -1) != ""
		|| text.substring(100, 200) != ""
		|| text.substring(3, 2) != "l")
		return 4;
	if (text.substring(-2) != "hello" || text.substring(9) != "" || text.substring(2) != "llo")
		return 5;
	// substr is unaffected: a negative length selects nothing instead of swapping.
	var length = -1;
	if (text.substr(1, length) != "" || text.substr(4, -3) != "")
		return 6;
	return 42;
}
