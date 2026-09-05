function main():Int {
	var value = 0;
	var outer = () -> {
		var inner = () -> {
			value++;
			return value;
		};
		return inner();
	};
	return outer() + outer();
}
