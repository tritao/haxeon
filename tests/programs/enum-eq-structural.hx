enum Shape {
	Dot;
	Circle(radius:Int);
	Pair(first:Int, second:Int);
}

// Type.enumEq compares the constructor and then each argument, recursively, however the values were made.
function main():Int {
	var checks = [
		Type.enumEq(Circle(1), Circle(1)),
		!Type.enumEq(Circle(1), Circle(2)),
		!Type.enumEq(Dot, Circle(1)),
		Type.enumEq(Pair(1, 2), Pair(1, 2)),
		!Type.enumEq(Pair(1, 2), Pair(2, 1)),
		Type.enumEq(Dot, Dot)
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
