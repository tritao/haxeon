function find<T>(values:Array<T>, value:T):Int {
	if (values == null)
		return -2;
	for (i in 0...values.length)
		if (values[i] == value)
			return i;
	return -1;
}

function findReversed<T>(value:T, values:Array<T>):Int {
	return find(values, value);
}

function main():Int {
	var values:Array<Null<Int>> = [1, null];
	if (find(values, null) != 1 || findReversed(null, values) != 1)
		return 1;
	if (find([], null) != -1 || findReversed(null, []) != -1)
		return 2;
	if (find(null, null) != -2)
		return 3;
	return 42;
}
