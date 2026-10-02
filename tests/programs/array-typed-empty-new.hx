function main():Int {
	var values = new Array<Int>();
	var index = 0;
	while (index < 4) {
		values.push(index);
		index++;
	}
	var floats = new Array<Float>();
	floats.push(1.5);
	if (values.length != 4 || floats.length != 1)
		return 0;
	return values[0] + values[1] + values[2] + values[3] + 36;
}
