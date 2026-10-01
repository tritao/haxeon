// Type.enumIndex is the position of an enum value's constructor in its declaration.
enum Shape {
	Circle(radius:Int);
	Square;
	Triangle(a:Int, b:Int);
}

function main():Int {
	var shapes = [Square, Circle(3), Triangle(1, 2)];
	var checks = [
		Type.enumIndex(Circle(9)) == 0,
		Type.enumIndex(Square) == 1,
		Type.enumIndex(Triangle(1, 1)) == 2,
		Type.enumIndex(shapes[0]) == 1,
		Type.enumIndex(shapes[1]) == 0,
		Type.enumIndex(shapes[2]) == 2
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
