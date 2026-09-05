function main():Int {
	try {
		if (1 == 1)
			throw "branch";
		return 0;
	} catch (error:Dynamic) {
		return 42;
	}
}
