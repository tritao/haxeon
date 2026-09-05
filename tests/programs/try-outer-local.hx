function main():Int {
	var value = 1;
	try {
		value = 42;
		throw "updated";
	} catch (error:Dynamic) {
		return value;
	}
}
