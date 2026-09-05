function main():Int {
	try {
		throw 42;
	} catch (error:Int) {
		return error;
	}
}
