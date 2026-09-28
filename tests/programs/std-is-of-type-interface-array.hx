interface Shape {
	function area():Float;
}

class Circle implements Shape {
	public function new() {}

	public function area():Float
		return 1.0;
}

function main():Int {
	var shape:Shape = new Circle();
	var shapes:Array<Shape> = [shape];
	if (!Std.isOfType(shape, Circle))
		return 1;
	if (!Std.isOfType(shapes[0], Circle))
		return 2;
	if (!Std.isOfType(shapes[0], Shape))
		return 3;
	return 42;
}
