// Array.concat takes its argument as any call does: a Null<Array<T>> (here an optional field) is read as the array, as in Haxe,
// and an empty literal is typed from the receiver's element type.
typedef Parts = {
	final items:Array<Int>;
	final ?extra:Array<Int>;
}

function main():Int {
	var parts:Parts = {items: [10, 20], extra: [12]};
	var all = parts.items.concat(parts.extra),
		same = all.concat([]);
	var total = 0;
	for (value in same)
		total += value;
	return same.length == 3 ? total : 1;
}
