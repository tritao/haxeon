function fail():Int {
	throw "boom";
}

function main():Int {
	var value = 0;
	try {
		fail();
	} catch (error:Dynamic) {
		value = 42;
	}
	return value;
}
