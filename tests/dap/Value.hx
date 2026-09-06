function value():Int {
	var result = 43;
	if (true) {
		var scoped = result + 100;
		result = scoped - 99;
		scoped = scoped + 0;
	}
	result = result - 1;
	return result;
}
