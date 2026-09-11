function main():Int {
	var values = new Array<Int>(0);
	var alias = values;
	for (index in 0...20)
		values.push(index);
	if (alias.length != 20 || alias[0] != 0 || alias[19] != 19)
		return 1;
	values[24] = 40;
	if (alias.length != 25 || alias[20] != 0 || alias[24] != 40)
		return 2;
	alias.unshift(41);
	if (values[0] != 41 || values[25] != 40)
		return 3;
	values.resize(30);
	if (alias.length != 30 || alias[26] != 0 || alias[29] != 0)
		return 4;
	return alias[0] + alias[25] - 39;
}
