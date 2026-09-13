function main():Int {
	var combined = "ha" + "xeon",
		left:Dynamic = "same",
		right:Dynamic = "sa" + "me";
	return combined.length == 6 && combined == "haxeon" && combined.charCodeAt(0) == 104 && left == right ? 42 : 0;
}
