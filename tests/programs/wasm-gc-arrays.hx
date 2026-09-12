class WasmGcArrayItem {
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var values = [20, 22], alias = values, iterator = values.iterator();
	if (!iterator.hasNext() || iterator.next() != 20)
		return 0;
	values.push(5);
	if (iterator.next() != 22 || iterator.next() != 5 || iterator.hasNext())
		return 0;
	values[15] = 40;
	if (alias.length != 16)
		return 0;
	if (alias[3] != 0 || alias[14] != 0 || alias[15] != 40)
		return 0;

	var items = [new WasmGcArrayItem(10)];
	items.push(new WasmGcArrayItem(32));
	if (items[0].value != 10 || items[1].value != 32)
		return 0;

	var fractions = [0.5, 1.5];
	fractions.push(2.5);
	if (fractions[0] != 0.5 || fractions[2] != 2.5)
		return 0;
	var flags = [false, true];
	flags.push(false);
	if (flags[0] || !flags[1] || flags[2])
		return 0;
	return 42;
}
