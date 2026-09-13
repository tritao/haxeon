function main():Int {
	var fields = "a,,b,".split(",");
	if (fields.length != 4 || fields[0] != "a" || fields[1] != "" || fields[2] != "b" || fields[3] != "")
		return 0;
	var unmatched = "abc".split("x");
	if (unmatched.length != 1 || unmatched[0] != "abc")
		return 0;
	var empty = "".split("");
	if (empty.length != 0)
		return 0;
	var characters = "é✓".split("");
	return characters.length == 2 && characters[0] == "é" && characters[1] == "✓" ? 42 : 0;
}
