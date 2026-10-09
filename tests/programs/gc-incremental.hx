import hl.Gc;

class IncrementalCell {
	public var next:IncrementalCell;
	public var value:Int;

	public function new(value:Int, next:IncrementalCell) {
		this.value = value;
		this.next = next;
	}
}

function main():Int {
	if (!Gc.incrementalSupported())
		return 42;
	Gc.enable(false);
	if (!Gc.beginFrame(0.0) || Gc.frameRemaining() != 0.0 || Gc.step(1000.0) || Gc.incrementalPending()) return 5;
	Gc.endFrame();
	if (Gc.frameRemaining() != -1.0) return 6;
	var head:IncrementalCell = null;
	for (i in 0...100000)
		head = new IncrementalCell(i, head);
	var before = Gc.collections();
	if (Gc.step(0.001) || !Gc.incrementalPending())
		return 1;
	var finished = false;
	for (slice in 0...10000) {
		// Exercise generated allocations and reference stores while a cycle is pending.
		for (i in 0...32)
			head = new IncrementalCell(1, head);
		if (Gc.step(1000.0)) {
			finished = true;
			break;
		}
	}
	if (!finished || Gc.incrementalReclaiming() || Gc.incrementalPending() || Gc.collections() != before + 1.0)
		return 2;
	var count = 0;
	var cursor = head;
	while (cursor != null) {
		count++;
		cursor = cursor.next;
	}
	if (count <= 100000 || head.value != 1)
		return 3;
	Gc.step(0.001);
	Gc.major();
	if (Gc.incrementalPending() || head.value != 1)
		return 4;
	Gc.enable(true);
	return 42;
}
