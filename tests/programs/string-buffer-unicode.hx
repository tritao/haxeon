function main():Int {
	// Characters beyond ASCII go through the shared one-character cache (below 256) or a fresh string (above it).
	var buf = new StringBuf();
	buf.addChar(65);
	buf.addChar(0xE9);
	buf.addChar(0x263A);
	buf.addSub("h\u00E9llo", 1, 2);
	var expected = "A\u00E9\u263A\u00E9l";
	if (buf.toString() != expected || buf.length != expected.length || buf.length != 5)
		return 1;
	var text = "h\u00E9llo\u263A";
	if (text.charAt(1) != "\u00E9" || text.charAt(5) != "\u263A" || text.charAt(6) != "" || text.charAt(-1) != "")
		return 2;
	if (String.fromCharCode(0x263A) != "\u263A" || String.fromCharCode(0xE9) != "\u00E9" || text.charAt(5).charCodeAt(0) != 0x263A)
		return 3;
	return 42;
}
