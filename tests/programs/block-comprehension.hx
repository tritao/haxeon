function main():Int {
	var values:Array<Int> = [
		for (index in 0...2) {
			var value = index + 20;
			value;
		}
	];
	return values[0] + values[1] + 1;
}
