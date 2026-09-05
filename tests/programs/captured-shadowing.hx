function main():Int {
	var value = 39;
	var outer = () -> {
		value = value + 1;
		return value;
	};
	var result = outer();
	if (true) {
		var value = 0;
		var inner = () -> {
			value = value + 1;
			return value;
		};
		result = result + inner() + 1;
	}
	return result;
}
