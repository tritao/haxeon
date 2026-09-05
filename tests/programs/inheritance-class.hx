class Box {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

class Child extends Box {
	public var extra:Int;

	public function new(value:Int) {
		this.value = value;
		this.extra = 1;
	}
}

function main():Int {
	var box = new Child(42);
	return box.value + box.extra;
}
