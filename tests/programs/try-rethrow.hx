function main():Int {
	try {
		throw "boom";
	} catch (error:Dynamic) {
		throw error;
	}
}
