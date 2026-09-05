class Item {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var values = new Array<Item>(0);
	var index = 0;
	while (index < 5) {
		values.push(new Item(index));
		index++;
	}
	var last = values.pop();
	return last.value + values.length;
}
