function main():Int {
	// Explicit iterator() with hasNext()/next() over Int, Float and reference elements.
	var ints = [3, 4, 5];
	var floats = [0.5, 1.5, 2.0];
	var words = ["a", "bc", "def"];
	var intSum = 0;
	var intIterator = ints.iterator();
	while (intIterator.hasNext())
		intSum += intIterator.next();
	var floatSum = 0.0;
	var floatIterator = floats.iterator();
	while (floatIterator.hasNext())
		floatSum += floatIterator.next();
	var letters = 0;
	var wordIterator = words.iterator();
	while (wordIterator.hasNext())
		letters += wordIterator.next().length;
	// Many short-lived iterators must not exhaust or leak collector state.
	var total = 0;
	for (round in 0...200000) {
		var iterator = ints.iterator();
		while (iterator.hasNext())
			total += iterator.next();
	}
	if (intSum != 12 || floatSum != 4.0 || letters != 6 || total != 2400000)
		return 1;
	return 42;
}
