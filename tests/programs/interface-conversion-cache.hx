import hl.Gc;

interface Shape {
	function area():Float;
}

interface Named extends Shape {
	function label():Int;
}

class Square implements Named {
	var side:Float;

	public function new(side:Float) {
		this.side = side;
	}

	public function area():Float {
		return side * side;
	}

	public function label():Int {
		return 7;
	}
}

class Cube extends Square {
	public function new(side:Float) {
		super(side);
	}
}

function measure(shape:Shape):Float {
	return shape.area();
}

function name(named:Named):Int {
	return named.label();
}

function main():Int {
	var objects:Array<Square> = [new Square(2.0), new Cube(3.0)];
	var sum = 0.0;
	var labels = 0;
	// The first conversion of each object allocates its virtual; later ones reuse it.
	for (object in objects) {
		sum += measure(object);
		labels += name(object);
	}
	var before = Gc.totalAllocated();
	for (i in 0...1000)
		for (object in objects) {
			sum += measure(object);
			labels += name(object);
		}
	var allocated = Gc.totalAllocated() - before;
	if (allocated > 1024.0)
		return 1;
	// 1001 rounds of (4 + 9) areas and 2 labels of 7 each.
	return sum == 13013.0 && labels == 14014 ? 42 : 2;
}
