import hl.Gc;

function main():Int {
	var failures = 0;
	if (Gc.markThreshold() < 0.19 || Gc.markThreshold() > 0.21)
		failures += 1;
	Gc.setMarkThreshold(0.5);
	if (Gc.markThreshold() < 0.49 || Gc.markThreshold() > 0.51)
		failures += 2;
	Gc.setMarkThreshold(100.0);
	if (Gc.markThreshold() > 4.01)
		failures += 4;
	Gc.setMarkThreshold(0.2);
	var before = Gc.collections();
	Gc.enable(false);
	var keep:Array<Array<Int>> = [];
	for (i in 0...20000)
		keep.push([i, i, i, i, i, i, i, i]);
	if (Gc.collections() != before)
		failures += 8;
	Gc.enable(true);
	Gc.major();
	if (Gc.collections() <= before)
		failures += 16;
	if (Gc.lastPauseMicros() <= 0.0)
		failures += 32;
	if (Gc.maxPauseMicros() < Gc.lastPauseMicros())
		failures += 64;
	if (Gc.heapBytes() <= 0.0)
		failures += 128;
	return failures == 0 ? 42 : failures;
}
