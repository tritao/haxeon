function main():Int {
	var total = 0;
	for (value in 1...4)
		total = total + value;
	var values = [for (value in 40...43) value];
	return values[0] + values.length - total + 5;
}
