function main():Int {
	var value = 1;
	var items = new Array<Int>(1);
	try {
		value = 42;
		items[2];
	} catch (error:Dynamic) {
		return value;
	}
	return 0;
}
