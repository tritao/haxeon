class Box {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var box:Null<Box> = new Box(42);
	var result = 0;
	if (box != null && box.value == 42)
		result = result + 21;
	if (box == null || box.value != 42)
		return 0;
	return result + 21;
}
