function main():Int {
	var values = [1, 21, 20];
	values.sort((left, right) -> left - right);
	return values[0] + values[1] + values[2];
}
