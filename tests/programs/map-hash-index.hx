function main():Int {
	// Growth across several capacity doublings, with colliding and negative keys.
	var ints = new Map<Int, Int>();
	for (i in 0...5000)
		ints.set(i * 64 - 100000, i);
	var count = 0;
	for (_ in ints.keys())
		count++;
	if (count != 5000)
		return 1;
	for (i in 0...5000)
		if (ints.get(i * 64 - 100000) != i)
			return 2;
	if (ints.exists(1) || ints.get(1) != null)
		return 3;

	// Overwrite keeps one entry; interleaved removes keep the rest reachable.
	for (i in 0...5000)
		ints.set(i * 64 - 100000, i + 1);
	for (i in 0...5000)
		if (i % 3 != 0 && !ints.remove(i * 64 - 100000))
			return 4;
	if (ints.remove(7))
		return 5;
	for (i in 0...5000) {
		var v = ints.get(i * 64 - 100000);
		if (i % 3 == 0) {
			if (v != i + 1)
				return 6;
		} else if (v != null)
			return 7;
	}
	count = 0;
	for (k in ints.keys())
		count++;
	if (count != 1667)
		return 8;

	// Re-adding removed keys, then copy, clear and reuse.
	for (i in 0...100)
		ints.set(i * 64 - 100000 + 1, i);
	var copy = ints.copy();
	ints.clear();
	if (ints.exists(-100000) || ints.get(-99999) != null)
		return 9;
	ints.set(-100000, 5);
	if (ints.get(-100000) != 5 || copy.get(-100000) != 1 || copy.get(-99999) != 0 || copy.get(i64Key(99)) != 99)
		return 10;
	count = 0;
	for (k in copy.keys())
		count++;
	if (count != 1767)
		return 11;

	var strings = new Map<String, Int>();
	for (i in 0...3000)
		strings.set("key" + i, i);
	for (i in 0...3000)
		if (i % 2 == 0)
			strings.remove("key" + i);
	for (i in 0...3000)
		if (strings.get("key" + i) != (i % 2 == 0 ? null : i))
			return 12;
	return 42;
}

function i64Key(i:Int):Int
	return i * 64 - 100000 + 1;
