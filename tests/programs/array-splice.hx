class SpliceBox {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var ints = [10, 20, 30, 40];
	var removed = ints.splice(1, 2);
	if (removed.length != 2 || removed[0] != 20 || removed[1] != 30 || ints.length != 2 || ints[1] != 40)
		return 1;
	var strings = ["a", "b", "c"];
	var middle = strings.splice(-2, 1);
	if (middle[0] != "b" || strings.length != 2 || strings[1] != "c")
		return 2;
	if (strings.splice(10, 1).length != 0 || strings.splice(0, -1).length != 0 || strings.length != 2)
		return 3;
	var floats = [1.5, 2.5];
	if (floats.splice(0, 1)[0] != 1.5)
		return 4;
	var bools = [true, false];
	if (!bools.splice(0, 1)[0])
		return 5;
	var boxes = [new SpliceBox(41), new SpliceBox(42)];
	if (boxes.splice(1, 1)[0].value != 42 || boxes.length != 1)
		return 6;
	var shifted = [10, 20, 30];
	if (shifted.shift() != 10 || shifted.length != 2 || shifted[0] != 20)
		return 7;
	var shiftedStrings = ["first", "second"];
	if (shiftedStrings.shift() != "first" || shiftedStrings[0] != "second")
		return 8;
	return 42;
}
