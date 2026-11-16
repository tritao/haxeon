// hl.Gc.stats reports HashLink's counters as Haxe's does: bytes and allocations grow as a program allocates.
function main():Int {
	var before = hl.Gc.stats();
	var keep = [for (i in 0...1000) 'x$i'];
	var after = hl.Gc.stats();
	return keep.length == 1000 && after.totalAllocated > before.totalAllocated
		&& after.allocationCount > before.allocationCount && after.currentMemory > 0 ? 42 : 1;
}
