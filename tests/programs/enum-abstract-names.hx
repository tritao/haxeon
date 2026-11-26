// A raw-value enum or a Flags enum abstract prints its names wherever it becomes a String: concatenation, interpolation,
// Std.string and toString(). A code outside the cases, made by a cast, prints as Owner(raw).
enum Shape:Int {
	Circle = 1;
	Square = 2;
}

enum Mime:String {
	Json = "application/json";
}

enum abstract Access(Int) implements Flags {
	var Read = 1;
	var Write = 2;
}

function main():Int {
	var shape = Shape.Square;
	if ("shape " + shape != "shape Square")
		return 1;
	if ('${shape}' != "Square" || Std.string(shape) != "Square" || shape.toString() != "Square")
		return 2;
	if (Std.string(Mime.Json) != "Json")
		return 3;
	var unknown:Shape = cast 9;
	if ("" + unknown != "Shape(9)")
		return 4;
	var access = Access.Read | Access.Write;
	if ("" + access != "Access[Read | Write]" || Std.string(access) != "Access[Read | Write]")
		return 5;
	if (Std.string(3) != "3" || Std.string(1.5) != "1.5")
		return 6;
	var maybe:Null<Shape> = null;
	if ("" + maybe != "null" || '${maybe}' != "null")
		return 7;
	maybe = Shape.Circle;
	if ("" + maybe != "Circle" || Std.string(maybe) != "Circle")
		return 8;
	// Interpolation joins mixed branches as Std.string's Dynamic parameter does.
	var width:Null<Float> = null;
	if ('${width == null ? "style" : width}' != "style")
		return 9;
	return 42;
}
