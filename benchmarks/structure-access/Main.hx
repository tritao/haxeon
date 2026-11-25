// What a field read costs by the kind of receiver, the baseline for the structure-values representation
// (docs/design/STRUCTURE_VALUES.md, slice 1). Each line is the best of RUNS runs of READS reads, in ns per read; the
// checksum keeps the reads from being optimized out and must be the same for every build.
//
// Build and run with each compiler on the same machine, quiet if possible (read the ratios, not the digits):
//   haxeon build benchmarks/structure-access/Main.hx --build-mode=release ... ; hl out.hl
//   .tools/haxe/haxe -cp benchmarks/structure-access -main Main -hl stock.hl ; hl stock.hl
//
// Cases:
//   class          a field of a class instance (the baseline)
//   structure      a field of a structure literal's record, the representation's exact shape
//   erased owner   a field of a generic class read through G<Dynamic> (an erased generic owner: Haxeon dispatches through a
//                  generated accessor, the case that costs lru its 20 to 45%)
//   dynamic        a field read by name through Dynamic, which a dispatcher's last arm does
// Later slices add a class seen as a structure and a wider literal seen through a narrower structure type.
class Point {
	public var x:Int;
	public var y:Int;

	public function new(x:Int, y:Int) {
		this.x = x;
		this.y = y;
	}
}

class Box<T> {
	public var value:T;

	public function new(value:T)
		this.value = value;
}

typedef Pair = {x:Int, y:Int};

class Main {
	static inline final READS = 20000000;
	static inline final RUNS = 5;
	static inline final COUNT = 64;

	static function main() {
		var classes = [for (i in 0...COUNT) new Point(i, i + 1)],
			structures:Array<Pair> = [for (i in 0...COUNT) {
				x: i, y: i + 1
			}],
			boxes:Array<Box<Dynamic>> = [for (i in 0...COUNT) new Box<Int>(i)],
			dynamics:Array<Dynamic> = [for (i in 0...COUNT) {
				x: i, y: i + 1
			}];
		report("class", () -> {
			var sum = 0;
			for (i in 0...READS)
				sum += classes[i & (COUNT - 1)].x;
			sum;
		});
		report("structure", () -> {
			var sum = 0;
			for (i in 0...READS)
				sum += structures[i & (COUNT - 1)].x;
			sum;
		});
		report("erased owner", () -> {
			var sum = 0;
			for (i in 0...READS) {
				var value:Int = boxes[i & (COUNT - 1)].value;
				sum += value;
			}
			sum;
		});
		report("dynamic", () -> {
			var sum = 0;
			for (i in 0...READS) {
				var value:Int = dynamics[i & (COUNT - 1)].x;
				sum += value;
			}
			sum;
		});
	}

	static function report(name:String, body:() -> Int):Void {
		var best = Math.POSITIVE_INFINITY, checksum = 0;
		for (_ in 0...RUNS) {
			var start = haxe.Timer.stamp();
			checksum = body();
			var elapsed = haxe.Timer.stamp() - start;
			if (elapsed < best)
				best = elapsed;
		}
		var nanoseconds = Math.round(best * 1e9 / READS * 100) / 100;
		Sys.println(StringTools.rpad(name, " ", 14) + ' $nanoseconds ns  (checksum $checksum)');
	}
}
