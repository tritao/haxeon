function main():Int {
	var values = new Array<Int>(0);
	var index = 0;
	while (index < 8) {
		if (values.push(index) != index + 1)
			return 0;
		index++;
	}
	if (values.length != 8)
		return 0;
	return values[0] + values[1] + values[2] + values[3] + values[4] + values[5] + values[6] + values[7] + 14;
}
