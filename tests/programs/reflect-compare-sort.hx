function main():Int {
	var values = ["z", "a", "m"];
	values.sort(Reflect.compare);
	return values.join("") == "amz" ? 42 : 1;
}
