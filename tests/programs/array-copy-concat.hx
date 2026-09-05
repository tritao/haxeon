class Box {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var values = new Array<Int>(2);
	values[0] = 20;
	values[1] = 22;
	var copy = values.copy();
	if (copy.length != 2 || copy[0] != 20 || copy[1] != 22)
		return 0;
	var suffix = new Array<Int>(1);
	suffix[0] = 5;
	var combined = copy.concat(suffix);
	if (combined.length != 3 || combined[2] != 5)
		return 0;
	if (copy.length != 2)
		return 0;
	var labels = new Array<String>(1);
	labels[0] = "ok";
	var labelCopy = labels.copy();
	var labelCombined = labels.concat(labelCopy);
	if (labelCombined[1] != "ok")
		return 0;
	var boxes = new Array<Box>(1);
	boxes[0] = new Box(40);
	var boxCombined = boxes.concat(boxes.copy());
	return labelCombined[1].length + boxCombined[1].value;
}
