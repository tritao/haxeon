function main():Int {
	var value = 1;
	try {
		if (value == 1) {
			value = 42;
			throw "branch";
		}
	} catch (error:Dynamic) {
		return value;
	}
	return 0;
}
