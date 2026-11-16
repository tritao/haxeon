// After a switch, what its continuing cases assigned holds: a local narrowed to null before the switch and assigned in a
// case is no longer known to be null, as after an if.
enum Shape {
	Dot;
	Box(n:Int);
}
function probe(n:Int):Null<String> return n > 100 ? "probe" : null;
function inner(n:Int):Null<String> return n > 1 ? 'inner $n' : null;
function walk(shapes:Array<Shape>):Null<String> {
	for (index in 0...shapes.length) {
		var shape = shapes[index], found = probe(index);
		if (found != null)
			return found;
		found = probe(index + 1);
		if (found != null)
			return found;
		switch shape {
			case Box(n):
				found = inner(n);
			default:
		}
		if (found != null)
			return found;
	}
	return null;
}
function main():Int {
	var r = walk([Dot, Box(5), Dot]);
	return r == "inner 5" ? 42 : 1;
}
