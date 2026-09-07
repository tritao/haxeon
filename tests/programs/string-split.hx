function main():Int {
	var parts = "alpha.beta.gamma".split(".");
	if (parts.length != 3 || parts[0] != "alpha" || parts[1] != "beta" || parts[2] != "gamma")
		return 0;
	var characters = "ab".split("");
	return characters.length == 2 && characters[0] == "a" && characters[1] == "b" ? 42 : 0;
}
