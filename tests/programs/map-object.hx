class Item {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var values = new Map<String, Item>();
	values["answer"] = new Item(42);
	if (!values.exists("answer") || values.size() != 1)
		return 0;
	var item = values.get("answer");
	if (item.value != 42)
		return 0;
	var items = values.values();
	if (items.length != 1 || items[0].value != 42)
		return 0;
	if (!values.remove("answer") || values.exists("answer"))
		return 0;
	return 42;
}
