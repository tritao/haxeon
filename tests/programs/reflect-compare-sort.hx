function main():Int {
	var values = ["\u0100", "a", "\u00FF", "aa"];
	values.sort(Reflect.compare);
	return values.join("|") == "a|aa|\u00FF|\u0100" && Reflect.compare("same", "same") == 0 && Reflect.compare("short", "shorter") < 0 ? 42 : 1;
}
