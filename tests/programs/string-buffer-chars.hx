function main():Int {
	var buf = new StringBuf();
	if (buf.length != 0 || buf.toString() != "")
		return 1;
	buf.add("abc");
	buf.add(12);
	buf.add(1.5);
	buf.add(true);
	if (buf.toString() != "abc121.5true" || buf.length != 12)
		return 2;
	buf.addChar(65);
	buf.addChar(66);
	buf.addSub("hello", 1, 3);
	buf.addSub("world", 2);
	var expected = "abc121.5trueABellrld";
	if (buf.toString() != expected || buf.length != expected.length)
		return 3;

	// toString is a snapshot: the buffer keeps accepting pieces afterwards.
	var first = buf.toString();
	buf.add("!");
	if (first != expected || buf.toString() != expected + "!")
		return 4;

	// Growth across many reallocations.
	var big = new StringBuf();
	for (i in 0...100000)
		big.add("xy");
	var joined = big.toString();
	if (big.length != 200000 || joined.length != 200000 || joined.charAt(199999) != "y" || joined.charAt(0) != "x")
		return 5;

	// charAt: in range, out of range, and repeated.
	var text = "hello";
	if (text.charAt(1) != "e" || text.charAt(4) != "o" || text.charAt(5) != "" || text.charAt(-1) != "" || text.charAt(0) + text.charAt(0) != "hh")
		return 6;

	// Characters from fromCharCode and charAt are ordinary strings: they compare, concatenate and index normally.
	var a = String.fromCharCode(97);
	if (a != "a" || a + a != "aa" || (a + "b").charAt(1) != "b")
		return 7;
	var line = new StringBuf();
	for (i in 0...60)
		line.add("ACGT".charAt(i % 4));
	if (line.toString().length != 60 || line.toString().charAt(59) != "T")
		return 8;
	return 42;
}
