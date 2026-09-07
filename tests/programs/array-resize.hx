function main():Int {
	var values = [40, 2];
	values.resize(4);
	if (values.length != 4 || values[2] != 0 || values[3] != 0)
		return 1;
	values.resize(2);
	return values[0] + values[1];
}
