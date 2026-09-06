class Item {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var values = new Map<String, Item>();
	values["one"] = new Item(10);
	values["two"] = new Item(32);
	var total = 0;
	for (item in values)
		total = total + item.value;

	var indexed = new Map<Int, Int>();
	indexed[3] = 4;
	indexed[5] = 6;
	for (indexValue in indexed)
		total = total + indexValue;
	return total;
}
