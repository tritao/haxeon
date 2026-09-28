// Haxe std constructs the Xml port relies on: implicit enum abstract values, unqualified enum abstract
// switch cases, block-valued initializers, @:isVar properties with inferred accessors, and iterator() for-in.
enum abstract Step(Int) {
	var First;
	var Second;
	var Tenth = 10;
	var Eleventh;
}

enum abstract Tag(String) {
	var Alpha;
	var Beta = "b";
}

class Bag {
	static var defaults:Map<String, Int> = {
		var m = new Map<String, Int>();
		m.set("one", 1);
		m;
	}

	@:isVar public var label(get, set):String;

	var items:Array<Int>;

	public function new() {
		items = [];
		label = "bag";
	}

	function get_label() {
		return label;
	}

	function set_label(value) {
		return this.label = value.toUpperCase();
	}

	public function add(value:Int, twice = false):Void {
		inline function push(v:Int)
			items.push(v);
		push(value);
		if (twice)
			push(value);
	}

	public function iterator():Iterator<Int> {
		return items.iterator();
	}

	public static function defaultOne():Int {
		var one = defaults.get("one");
		return one == null ? 0 : one;
	}
}

function stepName(step:Step):String {
	return switch step {
		case First: "first";
		case Second: "second";
		case Tenth: "tenth";
		case Eleventh: "eleventh";
		default: "other";
	};
}

function main():Int {
	if ((cast Second : Int) != 1 || (cast Eleventh : Int) != 11)
		return 1;
	if ((cast Alpha : String) != "Alpha" || (cast Beta : String) != "b")
		return 2;
	if (stepName(Second) != "second" || stepName(Eleventh) != "eleventh" || stepName(First) != "first")
		return 3;
	var bag = new Bag();
	if (bag.label != "BAG")
		return 4;
	bag.label = "sack";
	if (bag.label != "SACK")
		return 5;
	bag.add(2, true);
	bag.add(3);
	var total = 0;
	for (item in bag)
		total += item;
	var doubled = [for (item in bag) item * 2];
	if (total != 7 || doubled.join(",") != "4,4,6")
		return 6;
	var value = {
		var base = Bag.defaultOne();
		base + 41;
	};
	return value;
}
