function main():Int {
	var first:Dynamic = "dynamic value";
	var same:Dynamic = ["dynamic", "value"].join(" ");
	var different:Dynamic = "other";
	return first == same && first != different ? 42 : 1;
}
