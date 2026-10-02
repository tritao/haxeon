class Cell {
	public var next:Cell;
	public var value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	// A tiny live set that churns through a lot of garbage must not be re-marked every few megabytes: a major
	// collection waits for a minimum amount of allocation as well as a fraction of the heap.
	var live = new Cell(1);
	var collectionsBefore = hl.Gc.collections();
	var allocatedBefore = hl.Gc.totalAllocated();
	for (round in 0...64) {
		var head:Cell = null;
		for (i in 0...100000) {
			var cell = new Cell(i);
			cell.next = head;
			head = cell;
		}
	}
	var collections = hl.Gc.collections() - collectionsBefore;
	var allocated = hl.Gc.totalAllocated() - allocatedBefore;
	if (live.value != 1)
		return 1;
	// The loop really allocated (Wasm reports zero for both counters, which also satisfies the bound).
	if (allocated != 0 && allocated < 100000000)
		return 2;
	if (collections > 60)
		return 3;
	return 42;
}
