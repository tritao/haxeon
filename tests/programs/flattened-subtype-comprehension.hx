// A flattened comprehension whose items are a subtype of the declared element type builds an array of that element type:
// `var shapes:Array<Shape> = [for (x in xs) for (y in ys) new Square(...)]` reads every item back as a Shape.
class Shape {
	public function new() {}

	public function area():Float
		return 0;
}

class Square extends Shape {
	final side:Float;

	public function new(side:Float) {
		super();
		this.side = side;
	}

	override public function area():Float
		return side * side;
}

function main():Int {
	var sizes = [1.0, 2.0];
	var shapes:Array<Shape> = [for (a in sizes) for (b in sizes) new Square(a + b)];
	var filtered:Array<Shape> = [for (a in sizes) for (b in sizes) if (a != b) new Square(a * b)];
	var total = 0.0;
	for (shape in shapes)
		total += shape.area();
	shapes.push(new Shape());
	var checks = [
		shapes.length == 5,
		total == 4 + 9 + 9 + 16,
		filtered.length == 2 && filtered[0].area() == 4,
		shapes[4].area() == 0
	];
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
