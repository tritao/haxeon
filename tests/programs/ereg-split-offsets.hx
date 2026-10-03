// EReg.split on global and non-global patterns, with empty pieces at the edges and in the middle. The matching regression
// test for the JIT is tests/runtime/JitAddressTakenMain.hx, which runs stock Haxe's own EReg bytecode.
function main():Int {
	var comma = new EReg(",\\s*", "g");
	var parts = comma.split("a, b,c,   d");
	if (parts.length != 4 || parts.join("|") != "a|b|c|d")
		return 1;
	var cross = new EReg("x", "g");
	var pieces = cross.split("axbxxc");
	if (pieces.join("|") != "a|b||c")
		return 2;
	var none = new EReg("z", "").split("abc");
	if (none.length != 1 || none[0] != "abc")
		return 3;
	var edges = new EReg("/", "g").split("/a//b/");
	if (edges.length != 5 || edges.join("|") != "|a||b|")
		return 4;
	var total = 0;
	for (round in 0...200)
		total += new EReg("[,;]", "g").split("a,b;c,d;e,f").length;
	if (total != 200 * 6)
		return 5;
	return 42;
}
