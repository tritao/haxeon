function main():Int {
	var parts = "one two 𐍈".split(" ");
	var empty = "".split("");
	return parts.length == 3 && parts[0] == "one" && parts[1] == "two" && parts[2] == "𐍈" && empty.length == 0 ? 42 : 0;
}
