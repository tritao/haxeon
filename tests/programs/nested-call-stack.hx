// The stack of an exception thrown three calls deep, and of a caught one, names every Haxe frame with the line of its call,
// whichever calls a backend inlined.

class Shapes {
	public var total = 0;

	public function new() {}

	public function measure(depth:Int):Int {
		if (depth > 3)
			throw 'too deep: $depth';
		total += depth;
		return depth * 2;
	}

	public function walk(depth:Int):Int
		return measure(depth + 1) + 1;
}

function outer(shapes:Shapes, depth:Int):Int
	return shapes.walk(depth) + shapes.walk(depth + 1);

function check(value:Int):Int {
	if (value > 9)
		throw "large";
	return value;
}

function twice(value:Int):Int
	return check(value) * 2;

function step(value:Int):Int
	return twice(value + 1) + 1;

function frames():String {
	var names = [];
	for (item in haxe.CallStack.exceptionStack())
		switch item {
			case FilePos(Method(type, method), file, line): names.push('$type.$method:$line');
			case FilePos(LocalFunction(_), file, line): names.push('local:$line');
			case FilePos(_, file, line): names.push('$file:$line');
			default: names.push("?");
		}
	return names.join(" < ");
}

function main():Int {
	var shapes = new Shapes();
	var result = 0;
	try {
		result = outer(shapes, 1) + outer(shapes, 2);
	} catch (error:String) {
		Sys.println('$error: ${frames()}');
	}
	Sys.println('total ${shapes.total}');
	var sum = 0;
	try {
		for (value in 0...20)
			sum += step(value);
	} catch (error:String) {
		Sys.println('$error: ${frames()}');
	}
	Sys.println('sum $sum');
	return result == 0 ? 42 : 1;
}
