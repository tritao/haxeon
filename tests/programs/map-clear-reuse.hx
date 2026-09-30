function fill(map:Map<Int, Int>, start:Int, count:Int):Void {
	for (i in 0...count)
		map.set(start + i, (start + i) * 2);
}

function main():Int {
	var failures = 0;
	var ints:Map<Int, Int> = new Map();
	// Clear and refill with different keys and sizes so reused storage is exercised across growth.
	for (round in 0...6) {
		var count = round == 3 ? 900 : 40 + round * 7;
		fill(ints, round * 1000, count);
		var total = 0;
		for (key in ints.keys())
			total += ints.get(key) - key;
		var seen = 0;
		for (i in 0...count) {
			if (ints.get(round * 1000 + i) != (round * 1000 + i) * 2)
				failures += 1;
			seen++;
		}
		if (seen != count || total != Std.int((count * (count - 1) / 2) + round * 1000 * count))
			failures += 2;
		if (round > 0 && ints.exists((round - 1) * 1000))
			failures += 4;
		ints.remove(round * 1000);
		if (ints.exists(round * 1000))
			failures += 8;
		ints.clear();
		if (ints.exists(round * 1000 + 1))
			failures += 16;
	}
	var names:Map<String, Int> = new Map();
	for (round in 0...4) {
		for (i in 0...30 + round * 20)
			names.set("k" + round + "_" + i, i);
		var count = 0;
		for (key in names.keys())
			count++;
		if (count != 30 + round * 20 || names.get("k" + round + "_5") != 5)
			failures += 32;
		names.clear();
		if (names.exists("k" + round + "_5"))
			failures += 64;
	}
	return failures == 0 ? 42 : failures;
}
