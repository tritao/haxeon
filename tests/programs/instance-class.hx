class Box {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}

	public function get():Int {
		return this.value;
	}
}

function main():Int {
	var box = new Box(42);
	return box.get();
}
