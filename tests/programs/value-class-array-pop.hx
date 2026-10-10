// On HashLink a value class is a struct with no `hl_type *` header. Array.pop and Array.shift used to fetch the
// element through the reference array runtime as `Dyn` and cast it back, reading a header the struct does not have
// (SIGSEGV at address 0), whether or not the result was used.

@:value
class Point {
	public final x:Float;
	public final y:Int;

	public function new(x:Float, y:Int) {
		this.x = x;
		this.y = y;
	}
}

@:value
class Cell {
	public var count:Int;

	public function new(count:Int) {
		this.count = count;
	}
}

function points():Array<Point> {
	return [new Point(1.5, 10), new Point(2.5, 20), new Point(3.5, 30)];
}

function main():Int {
	var failures = 0;
	var popped = points();
	var last = popped.pop();
	if (last.x != 3.5 || last.y != 30 || popped.length != 2)
		failures += 1;
	var shifted = points();
	var first = shifted.shift();
	if (first.x != 1.5 || first.y != 10 || shifted.length != 2 || shifted[0].y != 20)
		failures += 2;
	var discarded = points();
	discarded.pop();
	discarded.shift();
	if (discarded.length != 1 || discarded[0].y != 20)
		failures += 4;
	// Trim repeated trailing points, the loop that first exposed the crash.
	var trimmed = [new Point(0, 1), new Point(1, 2), new Point(0, 1)];
	while (trimmed.length > 1 && trimmed[0].x == trimmed[trimmed.length - 1].x)
		trimmed.pop();
	if (trimmed.length != 2)
		failures += 8;
	var cells = [new Cell(1), new Cell(2)];
	var cell = cells.pop();
	cell.count += 5;
	if (cell.count != 7 || cells.length != 1 || cells[0].count != 1)
		failures += 16;
	return failures == 0 ? 42 : failures;
}
