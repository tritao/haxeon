function main():Int {
	var values = new Array<Int>(0);
	try {
		return values[0];
	} catch (error:Dynamic) {
		return 42;
	}
}
