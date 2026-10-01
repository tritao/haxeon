// `value.match(pattern)` on an enum value says whether the value matches the pattern, including nested patterns.
enum Shape {
	Circle(radius:Int);
	Square;
	Pair(first:Shape, second:Shape);
}

function describe(shape:Shape):Int {
	if (shape.match(Square))
		return 1;
	if (shape.match(Circle(0)))
		return 2;
	if (shape.match(Circle(_)))
		return 3;
	if (shape.match(Pair(Square, _)))
		return 4;
	return shape.match(Pair(_, Circle(_))) ? 5 : 6;
}

function main():Int {
	var shapes = [
		Square,
		Circle(0),
		Circle(7),
		Pair(Square, Circle(1)),
		Pair(Circle(1), Circle(2)),
		Pair(Circle(1), Square)
	];
	var found = 0;
	for (shape in shapes)
		if (shape.match(Circle(_)))
			found++;
	var checks = [
		describe(shapes[0]) == 1,
		describe(shapes[1]) == 2,
		describe(shapes[2]) == 3,
		describe(shapes[3]) == 4,
		describe(shapes[4]) == 5,
		describe(shapes[5]) == 6,
		found == 2,
		!Circle(3).match(Square),
		Circle(3).match(Circle(3))
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
