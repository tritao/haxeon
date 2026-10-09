enum Color {
	Red;
	Green;
	Blue;
}

// Array.lastIndexOf, from the end or from a position, for numbers, strings and enums.
function main():Int {
	var ints = [1, 2, 1], names = ["a", "b", "a"], colors = [Red, Green, Red];
	var checks = [
		ints.lastIndexOf(1) == 2
		&& ints.lastIndexOf(2) == 1
		&& ints.lastIndexOf(3) == -1,
		ints.lastIndexOf(1, 1) == 0
		&& ints.lastIndexOf(1, 5) == 2,
		ints.lastIndexOf(1, -2) == 0
		&& ints.lastIndexOf(2, -3) == -1,
		names.lastIndexOf("a") == 2
		&& names.lastIndexOf("b", 0) == -1,
		colors.lastIndexOf(Red) == 2
		&& colors.lastIndexOf(Green) == 1
		&& colors.lastIndexOf(Blue) == -1,
		([] : Array<Int>)
		.lastIndexOf(1) == -1
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
