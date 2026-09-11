function main():Int {
	var retained = [40];
	var index = 0;
	while (index < 200) {
		var transient = [index];
		if (transient[0] < 0)
			return 0;
		index = index + 1;
	}
	return retained[0] + 2;
}
