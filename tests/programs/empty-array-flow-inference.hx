function main():Int {
	var values = [];
	for (value in [42])
		switch value {
			case 42:
				values.push(value);
			default:
		}
	return values[0];
}
