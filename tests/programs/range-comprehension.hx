class Counter {
	public static var evaluations:Int = 0;

	public static function bound():Int {
		evaluations++;
		return 6;
	}
}

function main():Int {
	var squares = [for (i in 1...Counter.bound()) i * i]; // 1 4 9 16 25 = 55
	var evens = [for (i in -3...5) if (i % 2 == 0) i]; // -2 0 2 4 = 4
	var empty = [for (i in 4...4) i];
	var reversed = [for (i in 5...2) i];
	var total = 0;
	for (value in squares)
		total += value;
	for (value in evens)
		total += value;
	return total + empty.length + reversed.length + Counter.evaluations + squares.length; // 55+4+0+0+1+5 = 65
}
