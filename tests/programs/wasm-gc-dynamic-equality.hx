function main():Int {
	var first:Dynamic = "dynamic value";
	var same:Dynamic = ["dynamic", "value"].join(" ");
	var different:Dynamic = "other";
	var firstNumber:Dynamic = 40.5;
	var sameNumber:Dynamic = 40.5;
	var otherNumber:Dynamic = 41.5;
	var nanValue:Dynamic = 0.0 / 0.0;
	return first == same && first != different && firstNumber == sameNumber && firstNumber != otherNumber && !(nanValue == nanValue) ? 42 : 1;
}
