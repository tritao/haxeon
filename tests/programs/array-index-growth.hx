function main():Int {
	var values:Array<Int> = [];
	values[2] = 40;
	values[1] = 2;
	return values.length == 3 ? values[1] + values[2] : 0;
}
