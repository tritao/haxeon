// An abstract class's methods call the abstract ones, which each concrete subclass writes, through the class's own type.
abstract class Shape {
	public final name:String;

	public function new(name:String)
		this.name = name;

	public abstract function area():Int;

	public function describe():String
		return name + " " + area();
}

class Square extends Shape {
	final side:Int;

	public function new(side:Int) {
		super("square");
		this.side = side;
	}

	public function area():Int
		return side * side;
}

abstract class Scaled extends Shape {
	public abstract function factor():Int;

	public override function describe():String
		return super.describe() + " x" + factor();
}

class Doubled extends Scaled {
	public function new()
		super("doubled");

	public function area():Int
		return 10;

	public function factor():Int
		return 2;
}

function main():Int {
	var shapes:Array<Shape> = [new Square(3), new Doubled()];
	var total = 0;
	for (shape in shapes)
		total += shape.area();
	if (shapes[0].describe() != "square 9" || shapes[1].describe() != "doubled 10 x2")
		return 1;
	return total == 19 ? 42 : 2;
}
