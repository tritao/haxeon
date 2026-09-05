function main():Int {
	var values = new Array<Int>(4);
	values[0] = 40;
	values[1] = 0;
	values[2] = 2;
	values[3] = 100;
	var total = 0;
	for (value in values) {
		if (value == 0)
			continue;
		if (value == 100)
			break;
		total += value;
	}
	return total;
}
