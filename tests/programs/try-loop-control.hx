function main():Int {
	try {
		var value = 0;
		while (value < 1) {
			value = value + 1;
			break;
		}
		throw "loop";
	} catch (error:Dynamic) {
		return 42;
	}
}
