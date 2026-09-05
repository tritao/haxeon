function main():Int {
	var values = new Array<Int>(0);
	var alias = values;
	values.push(7);
	values.push(35);
	return alias[0] + alias[1];
}
