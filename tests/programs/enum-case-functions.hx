// A case with a payload named without a call is its constructor as a function, as in Haxe: qualified, bare where a function
// returning its enum is expected, or bare as the one case of that name in sight. A generic enum's takes its type arguments
// from the expected function type.
enum Shape {
	Circle(radius:Float);
	Rect(width:Float, height:Float);
	Label(text:String, ?size:Int);
}

enum Box<T> {
	Full(value:T);
	Empty;
}

typedef Figure = Shape;

function area(shape:Shape):Float
	return switch shape {
		case Circle(radius): 3 * radius * radius;
		case Rect(width, height): width * height;
		case Label(_, size): size == null ? 0 : size;
	}

function build(make:Float->Shape):Shape
	return make(2);

function main():Int {
	var circle = Shape.Circle;
	if (area(circle(1)) != 3)
		return 1;
	var rect:(Float, Float) -> Shape = Rect;
	if (area(rect(2, 3)) != 6)
		return 2;
	if (area(build(Circle)) != 12 || area(build(Shape.Circle)) != 12 || area(build(Figure.Circle)) != 12)
		return 3;
	var label = Label;
	if (area(label("x")) != 0 || area(label("x", 5)) != 5)
		return 4;
	var radii = [1.0, 2.0].map(Circle);
	if (area(radii[0]) + area(radii[1]) != 15)
		return 5;
	var full:Int->Box<Int> = Full;
	switch full(7) {
		case Full(value) if (value == 7):
		default:
			return 6;
	}
	return 42;
}
