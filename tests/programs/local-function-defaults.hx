function main():Int {
	var base = 30;
	function add(value:Int, extra:Int = 2, ?bonus:Int = 10):Int
		return base + value + extra + bonus;
	// add(0) uses both defaults: 30 + 0 + 2 + 10.
	if (add(0) != 42)
		return 1;
	if (add(1, 1) != 42)
		return 2;
	return add(10, 1, 1);
}
