function main():Int {
	var values:Map<String, Int> = new Map<String, Int>();
	values["left"] = 20;
	values["right"] = 22;
	var total = 0;
	for (_ => value in values)
		total = total + value;
	return total;
}
