class Key {
	public function new() {}
}

function sum(source:KeyValueIterable<Key, Int>):Int {
	var total = 0;
	for (key => value in source)
		total += value;
	return total;
}

function main():Int {
	var first = new Key();
	var second = new Key();
	var entries = new Map();
	entries.set(first, 19);
	entries.set(second, 23);
	return sum(entries);
}
