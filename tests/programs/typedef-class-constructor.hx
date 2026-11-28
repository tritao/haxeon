class Square {
	public var side:Int;

	public function new(side:Int) {
		this.side = side;
	}

	public function area():Int
		return side * side;
}

class Box<T> {
	public var value:T;

	public function new(value:T) {
		this.value = value;
	}
}

// `new` through a typedef constructs the class it names, as in Haxe.
typedef Shape = Square;
typedef ShapeAlias = Shape;
typedef IntBox = Box<Int>;

function main():Int {
	var shape = new Shape(2);
	if (!Std.isOfType(shape, Square) || shape.area() != 4)
		return 1;
	var aliased:Square = new ShapeAlias(3);
	if (aliased.area() != 9)
		return 2;
	var box = new IntBox(33);
	return box.value + shape.area() + 5;
}
