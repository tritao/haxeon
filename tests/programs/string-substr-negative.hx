function main():Int {
	var text = "hello";
	var last = -3;
	if (text.substr(last) != "llo")
		return 1;
	if (text.substr(last, 2) != "ll")
		return 2;
	if (text.substr(-10) != "hello" || text.substr(-10, 2) != "he")
		return 3;
	if (text.substr(1, 2) != "el" || text.substr(1, 100) != "ello" || text.substr(5) != "" || text.substr(2, 0) != "")
		return 4;
	var position = 1;
	if (text.substr(position, 1) != "e")
		return 5;
	// The position is evaluated once.
	var index = 1;
	if ("abcd".substr(index++, 2) != "bc" || index != 2)
		return 6;
	return 42;
}
