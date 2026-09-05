class Box {
	public var values:Array<Int>;

	public function new() {
		this.values = new Array<Int>(0);
	}

	public function add(value:Int):Void {
		this.values.push(value);
	}
}

function main():Int {
	var box = new Box();
	var index = 0;
	while (index < 6) {
		box.add(index);
		index++;
	}
	return box.values.length + box.values[5];
}
