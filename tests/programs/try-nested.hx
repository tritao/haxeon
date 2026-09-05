function main():Int {
	try {
		try {
			throw "boom";
		} catch (inner:Dynamic) {
			throw inner;
		}
	} catch (outer:Dynamic) {
		return 42;
	}
}
