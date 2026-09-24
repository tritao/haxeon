function main():Int {
	var a = 1, b = 2;
	for (_ in 0...1) {
		b = a;
		a = 3;
	}
	return a == 3 && b == 1 ? 42 : 1;
}
