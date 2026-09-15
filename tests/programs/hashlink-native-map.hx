import runtime.memory.NativeIntMap;

function main():Int {
	var values:NativeIntMap<Int> = new NativeIntMap<Int>(3);
	values.set(1, 11);
	values.set(9, 13);
	values.set(17, 17);
	if (values.length != 3 || values.capacity != 8 || !values.exists(9) || values.get(17) != 17)
		return 1;
	values.set(9, 23);
	if (values.length != 3 || values.get(9) != 23 || values.exists(99))
		return 2;
	try {
		values.get(99);
		return 3;
	} catch (_:Dynamic) {}
	values.clear();
	if (values.length != 0 || values.exists(1))
		return 4;
	values.dispose();
	try {
		values.set(29, 31);
		return 5;
	} catch (_:Dynamic) {}
	return 42;
}
