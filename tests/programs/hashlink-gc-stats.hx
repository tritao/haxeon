import haxe.Int64;
import runtime.memory.Gc;

function nonNegative(value:Int64):Bool
	return Int64.compare(value, Int64.ofInt(0)) >= 0;

function main():Int {
	var before = Gc.stats();
	if (!nonNegative(before.totalAllocated())
		|| !nonNegative(before.allocationCount())
		|| !nonNegative(before.heapBytes())
		|| !nonNegative(before.collectionCount())
		|| !nonNegative(before.markMicros()))
		return 1;

	Gc.collect();
	var after = Gc.stats();
	var monotonic = Int64.compare(after.totalAllocated(), before.totalAllocated()) >= 0
		&& Int64.compare(after.allocationCount(), before.allocationCount()) >= 0
		&& Int64.compare(after.heapBytes(), before.heapBytes()) >= 0
		&& Int64.compare(after.collectionCount(), before.collectionCount()) > 0;
	return monotonic ? 42 : 2;
}
