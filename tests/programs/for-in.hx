function main():Int {
	var values = new Array<Int>(3);
	values[0] = 10;
	values[1] = 20;
	values[2] = 12;
	var total = 0;
	for (value in values) {
		total = total + value;
	}
	return total;
}
