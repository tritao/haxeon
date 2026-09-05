function main():Int {
	var values = [for (value in 0...6) if (value % 2 == 0) value];
	return values[0] + values[1] + values[2] + values.length + 33;
}
