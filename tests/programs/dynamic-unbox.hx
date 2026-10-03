// Unboxing dynamic values to Int and Float: null, a box of the wanted kind (read directly by the JIT), and boxes of
// other kinds (converted by the runtime cast).
class Cell {
	public var count:Null<Int>;
	public var ratio:Null<Float>;

	public function new(count:Null<Int>, ratio:Null<Float>) {
		this.count = count;
		this.ratio = ratio;
	}
}

function toInt(value:Dynamic):Int
	return value;

function toFloat(value:Dynamic):Float
	return value;

function mix(hash:Int, value:Int):Int
	return hash * 31 + value;

function fold(hash:Int, value:Float):Int
	return mix(hash, Std.int(value * 1000.0));

function checksum():Int {
	var h = 7;
	var ints:Array<Dynamic> = [0, 1, -1, 42, 2147483647, -2147483648, null, 3.0, 7.9, -2.5, true, false];
	for (value in ints)
		h = mix(h, toInt(value));
	var floats:Array<Dynamic> = [0, 1, -1, 42, 0.5, -2.25, 1e10, null, true, false];
	for (value in floats)
		h = fold(h, toFloat(value));
	var cells = [
		new Cell(1, 2.5),
		new Cell(null, null),
		new Cell(-9, -0.125),
		new Cell(100000, 1e6)
	];
	for (round in 0...50)
		for (cell in cells) {
			var count = cell.count == null ? 0 : cell.count;
			var ratio = cell.ratio == null ? 0.0 : cell.ratio;
			h = mix(h, count);
			h = fold(h, ratio);
			if (cell.count != null)
				h = mix(h, cell.count + 1);
		}
	return h;
}

function main():Int {
	if (checksum() != -593932057)
		return 1;
	return 42;
}
