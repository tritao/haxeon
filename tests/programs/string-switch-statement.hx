function choose(value:String):Int {
	var result = 0;
	switch value {
		case "save":
			result = 42;
		case "discard":
			result = 1;
		default:
			result = 2;
	}
	return result;
}

function main():Int {
	var runtimeValue = "sa" + "ve";
	return choose(runtimeValue);
}
