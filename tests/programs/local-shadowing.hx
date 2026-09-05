function keep(value:Int):Int {
	if (true) {
		var value = 1;
		value = value + 1;
	}
	return value;
}

function main():Int {
	var value = 42;
	if (true) {
		var value = 7;
		if (true) {
			var value = 9;
			value = value + 1;
		}
		value = value + 1;
	}
	return keep(value);
}
