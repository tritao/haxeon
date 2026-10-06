@:value
class Rgb {
	public final r:Float;
	public final g:Float;

	public function new(r:Float, g:Float) {
		this.r = r;
		this.g = g;
	}

	public function sum():Float {
		return r + g;
	}
}

@:value
class Counter {
	public var count:Int;

	public function new(count:Int) {
		this.count = count;
	}
}

class Palette {
	static final colors:Map<String, Rgb> = ["wall" => new Rgb(1.0, 2.0), "glass" => new Rgb(3.0, 4.0)];

	public static function color(name:String):Rgb {
		var found = colors.get(name);
		return found == null ? new Rgb(0.0, 0.0) : found;
	}
}

function main():Int {
	var failures = 0;
	if (Palette.color("wall").sum() != 3.0 || Palette.color("glass").sum() != 7.0)
		failures += 1;
	if (Palette.color("door").sum() != 0.0)
		failures += 2;
	var byId:Map<Int, Rgb> = [];
	byId.set(7, new Rgb(5.0, 6.0));
	var hit:Rgb = cast byId.get(7);
	if (hit.sum() != 11.0 || byId.get(8) != null)
		failures += 4;
	var total = 0.0;
	for (key => value in byId)
		total += key + value.sum();
	for (value in byId)
		total += value.sum();
	if (total != 29.0)
		failures += 8;
	var counters:Map<String, Counter> = [];
	var original = new Counter(1);
	counters.set("a", original);
	original.count = 5;
	var stored:Counter = cast counters.get("a");
	if (stored.count != 1)
		failures += 16;
	stored.count = 9;
	var again:Counter = cast counters.get("a");
	if (again.count != 1)
		failures += 32;
	var copied = counters.copy();
	var fromCopy:Counter = cast copied.get("a");
	if (fromCopy.count != 1)
		failures += 64;
	return failures == 0 ? 42 : failures;
}
