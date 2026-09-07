function main():Int {
	var values = [20, 22];
	var mapped = [for (value in values) if (value > 20) value => value];
	return mapped.exists(22) ? mapped[22] + 20 : 0;
}
