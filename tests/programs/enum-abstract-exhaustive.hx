// A switch expression over a closed enum abstract that covers every declared value needs no default, as one over an enum
// does; a value outside the declared set throws instead of reaching the last arm.
enum abstract Shape(Int) from Int {
	var Circle = 1;
	var Square = 2;
	var Triangle = 3;
}

enum abstract Mime(String) {
	var Text = "text/plain";
	var Json = "application/json";
}

function sides(shape:Shape):Int
	return switch shape {
		case Circle: 0;
		case Square: 4;
		case Triangle: 3;
	};

function mimeCode(mime:Mime):Int
	return switch mime {
		case Text: 1;
		case Json: 2;
	};

// A statement switch that covers every value returns on every path, with no trailing return.
function corners(shape:Shape):Int {
	switch shape {
		case Circle:
			return 0;
		case Square:
			return 4;
		case Triangle:
			return 3;
	}
}

function main():Int {
	if (sides(Square) != 4 || sides(Triangle) != 3 || sides(Circle) != 0)
		return 1;
	if (mimeCode(Json) != 2 || mimeCode(Text) != 1)
		return 2;
	var unmatched = false;
	try
		sides(9)
	catch (error:Dynamic)
		unmatched = Std.string(error).indexOf("Unmatched") >= 0;
	if (!unmatched)
		return 4;
	if (corners(Square) != 4 || corners(Circle) != 0)
		return 5;
	var skipped = false;
	try
		corners(9)
	catch (error:Dynamic)
		skipped = Std.string(error).indexOf("Unmatched") >= 0;
	if (!skipped)
		return 6;
	return 42;
}
