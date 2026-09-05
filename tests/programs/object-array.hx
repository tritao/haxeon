class Box {
	var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var boxes = new Array<Box>(2);
	boxes[0] = new Box(40);
	boxes[1] = new Box(2);
	var first = boxes[0];
	var second = boxes[1];
	return first.value + second.value;
}
