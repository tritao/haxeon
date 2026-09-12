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
	if (item == null || item.value != 42)
		return 0;
	var items = values.values();
	if (!items.hasNext() || items.next().value != 42 || items.hasNext())
		return 0;
	if (!values.remove("answer") || values.exists("answer"))
		return 0;
	var keys = [
		"key00", "key01", "key02", "key03", "key04", "key05", "key06", "key07", "key08", "key09", "key10", "key11", "key12", "key13", "key14", "key15"
	];
	var index = 0;
	while (index < keys.length) {
		values[keys[index]] = new Item(index);
		index = index + 1;
	}
	var last = values.get("key15");
	if (values.size() != 16 || last == null || last.value != 15)
		return 0;
	return 42;
}
