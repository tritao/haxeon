function main():Int {
	var values:Array<Int> = [20, 22];
	var total = 0;
	for (index in 0...values.length)
		total += values[index];
	return total;
}
