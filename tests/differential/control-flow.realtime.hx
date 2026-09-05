function main():Int {
	var value = 0;
	var index = 0;
	while (index < 7) {
		if (index == 3) {
			index++;
			continue;
		}
		value = value + index;
		index++;
	}
	return value;
}
