function main():Int {
	var ints = new Array<Int>(5);
	ints[0] = 10;
	ints[1] = 20;
	ints[2] = 30;
	ints[3] = 40;
	ints[4] = 50;
	var middle = ints.slice(1, -1);
	if (middle.length != 3 || middle.indexOf(30) != 1 || middle.indexOf(99) != -1)
		return 1;
	var words = new Array<String>(3);
	words[0] = "zero";
	words[1] = "one";
	words[2] = "two";
	var tail = words.slice(1);
	if (tail.length != 2 || tail.indexOf("two") != 1)
		return 2;
	var floats = new Array<Float>(2);
	floats[0] = 1.5;
	floats[1] = 2.5;
	if (floats.indexOf(2.5) != 1)
		return 3;
	var flags = new Array<Bool>(2);
	flags[0] = false;
	flags[1] = true;
	if (flags.indexOf(true) != 1)
		return 4;
	return middle[0] + middle[2] - 18;
}
