class Counter {
	public var value:Int = 0;
	public var ratio:Float = 0.5;

	public function new() {}
}

class Reads {
	public static var count = 0;
}

function counter(target:Counter):Counter {
	Reads.count++;
	return target;
}

function main():Int {
	var local = 1;
	if (++local != 2 || local != 2)
		return 1;
	if (--local != 1 || local != 1)
		return 2;

	var box = new Counter();
	if (++box.value != 1 || box.value != 1)
		return 3;
	if (++box.ratio != 1.5 || box.ratio != 1.5)
		return 4;
	// The receiver of a field target is evaluated exactly once.
	if (++counter(box).value != 2 || Reads.count != 1)
		return 5;

	var values = [10, 20];
	var index = 0;
	// The index of an array target is evaluated exactly once.
	if (++values[index++] != 11 || values[0] != 11 || values[1] != 20 || index != 1)
		return 6;

	var attempts = 0;
	while (++attempts < 5) {}
	if (attempts != 5)
		return 7;
	return 42;
}
