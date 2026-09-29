class Counter {
	public static var evaluations:Int = 0;

	public static function bound():Int {
		evaluations++;
		return 5;
	}
}

function main():Int {
	var total = 0;
	// The bound is evaluated once, not per iteration.
	for (i in 0...Counter.bound())
		total += i; // 10
	// Empty and reversed ranges run zero times.
	for (i in 3...3)
		total += 1000;
	for (i in 5...2)
		total += 1000;
	// Negative bounds.
	for (i in -2...2)
		total += i; // -2 -1 0 1 => -2
	// Mutating the loop variable does not change the iteration count.
	var count = 0;
	for (i in 0...4) {
		i += 10;
		count++;
	}
	// break and continue, in nested loops.
	var inner = 0;
	for (a in 0...4) {
		if (a == 1)
			continue;
		for (b in 0...10) {
			if (b == 3)
				break;
			inner++;
		}
	}
	// 10 + (-2) + 4 + 9 (3 outer iterations x 3) + evaluations(1) = 22
	return total + count + inner + Counter.evaluations;
}
