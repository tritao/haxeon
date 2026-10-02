class Shape {
	public function new() {}
}

class Square extends Shape {
	public function new() {
		super();
	}

	public function side():Int {
		return 7;
	}
}

class Circle extends Shape {
	public function new() {
		super();
	}
}

class Counter {
	public static var made = 0;
}

function make():Shape {
	Counter.made++;
	return new Square();
}

function main():Int {
	var square:Shape = new Square(),
		circle:Shape = new Circle(),
		plain = new Shape(),
		nothing:Shape = null;
	var asSquare = Std.downcast(square, Square);
	var checks = [
		asSquare != null && asSquare.side() == 7,
		Std.downcast(circle, Square) == null,
		Std.downcast(plain, Square) == null,
		Std.downcast(nothing, Square) == null,
		Std.downcast(square, Shape) != null,
		Std.downcast(circle, Circle) != null
	];
	// The value is evaluated once.
	var once = Std.downcast(make(), Square);
	checks.push(once != null && Counter.made == 1);
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
