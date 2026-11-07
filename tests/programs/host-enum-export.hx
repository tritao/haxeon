enum HostChoice { Number(value:Int); }
class HostEnumExports {
	static final value:HostChoice = Number(42);
	public static function cached():HostChoice return value;
	@:expose public static function perform(count:Int):Int {
		var sum = 0;
		for (_ in 0...count) sum += switch cached() { case Number(value): value; };
		return sum;
	}
}
function main():Int {
	if (HostEnumExports.perform(8) != 336) return 1;
	#if !wasm
	for (count in [8, 1024]) {
		hl.Gc.censusStart(0);
		var before = hl.Gc.totalAllocated();
		var result = HostEnumExports.perform(count);
		var allocated = hl.Gc.totalAllocated() - before;
		hl.Gc.censusStop();
		if (result != 42 * count || allocated != 0) return 2;
	}
	#end
	return 42;
}
