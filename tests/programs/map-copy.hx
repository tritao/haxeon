class Box {
	public var n:Int;

	public function new(n:Int) {
		this.n = n;
	}
}

function main():Int {
	var failures = 0;

	// Independence in both directions, string keys.
	var a:Map<String, Int> = new Map();
	for (i in 0...5)
		a.set("k" + i, i);
	var b = a.copy();
	b.set("k0", 100);
	b.set("extra", 7);
	a.set("k1", 200);
	a.remove("k2");
	if (a.get("k0") != 0 || a.get("k1") != 200 || a.exists("k2") || a.exists("extra"))
		failures += 1;
	if (b.get("k0") != 100 || b.get("k1") != 1 || b.get("k2") != 2 || b.get("extra") != 7)
		failures += 2;

	// Growth past the small-index limit, then removals leave holes that a copy must carry.
	var big:Map<Int, Int> = new Map();
	for (i in 0...500)
		big.set(i, i * 3);
	for (i in 0...500)
		if (i % 7 == 0)
			big.remove(i);
	var bigCopy = big.copy();
	var count = 0;
	for (key in bigCopy.keys()) {
		count++;
		if (bigCopy.get(key) != key * 3 || key % 7 == 0)
			failures += 4;
	}
	if (count != 500 - 72)
		failures += 8;
	bigCopy.set(7000, 1);
	big.set(9000, 2);
	if (big.exists(7000) || bigCopy.exists(9000))
		failures += 16;
	// Refill the freed slots in the copy and in the original independently.
	for (i in 0...72) {
		bigCopy.set(i * 7, -1);
		big.set(i * 7, -2);
	}
	if (bigCopy.get(0) != -1 || big.get(0) != -2 || bigCopy.get(7 * 71) != -1 || big.get(7 * 71) != -2)
		failures += 32;

	// Other value kinds and an empty map.
	var floats:Map<String, Float> = new Map();
	floats.set("pi", 3.25);
	var floatCopy = floats.copy();
	floatCopy.set("pi", 1.5);
	if (floats.get("pi") != 3.25 || floatCopy.get("pi") != 1.5)
		failures += 64;
	var flags:Map<Int, Bool> = new Map();
	flags.set(1, true);
	flags.set(2, false);
	var flagCopy = flags.copy();
	if (flagCopy.get(1) != true || flagCopy.get(2) != false || !flagCopy.exists(2))
		failures += 128;
	var names:Map<String, String> = new Map();
	names.set("a", "alpha");
	var nameCopy = names.copy();
	names.set("a", "changed");
	if (nameCopy.get("a") != "alpha")
		failures += 256;
	var boxes:Map<String, Box> = new Map();
	boxes.set("x", new Box(5));
	var boxCopy = boxes.copy();
	boxCopy.get("x").n = 6;
	// A copy is shallow: both maps hold the same object.
	if (boxes.get("x").n != 6)
		failures += 512;
	var empty:Map<Int, Int> = new Map();
	var emptyCopy = empty.copy();
	emptyCopy.set(1, 1);
	if (empty.exists(1) || !emptyCopy.exists(1))
		failures += 1024;
	var cleared:Map<Int, Int> = new Map();
	for (i in 0...40)
		cleared.set(i, i);
	cleared.clear();
	var clearedCopy = cleared.copy();
	clearedCopy.set(3, 9);
	if (clearedCopy.get(3) != 9 || cleared.exists(3))
		failures += 2048;

	return failures == 0 ? 42 : failures;
}
