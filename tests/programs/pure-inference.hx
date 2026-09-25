typedef Limits = {var lower:Null<Float>; var upper:Null<Float>;};

class Bounds {
	public static var checks = 0;

	public static function inside(value:Float, low:Float, high:Float):Bool
		return value >= low && value <= high;

	public static function positive(value:Float):Bool
		return inside(value, 0.0, 1e300) && value != 0;

	public static function even(count:Int):Bool
		return count == 0 ? true : !odd(count - 1);

	static function odd(count:Int):Bool
		return count == 0 ? false : even(count - 1);

	public static function recorded(value:Float):Bool {
		checks++;
		return value > 0;
	}
}

// An impure toString only affects functions whose `+` may convert an object.
class Label {
	var renders = 0;

	public function new() {}

	public function toString():String {
		renders++;
		return "label";
	}
}

class Item {
	final flags:Int;

	public function new(flags:Int)
		this.flags = flags;

	public var visible(get, never):Bool;

	function get_visible():Bool
		return (flags & 1) != 0;
}

class Holder {
	public var item:Null<Item> = null;

	public function new() {}
}

function shown(holder:Holder):Bool
	return holder.item != null && holder.item.visible && holder.item != null;

function sum(limit:Int):Int {
	var total = 0;
	for (index in 0...limit)
		total += index;
	return total;
}

// Inferred-pure helpers (including mutually recursive ones) keep field narrowing.
function valid(limits:Limits):Bool
	return limits.lower != null
		&& Bounds.positive(limits.lower)
		&& Bounds.even(4)
		&& sum(3) == 3
		&& limits.lower < 10
		&& (limits.upper == null || limits.upper > limits.lower);

function main():Int {
	var holder = new Holder();
	holder.item = new Item(1);
	if (!shown(holder) || new Label().toString() != "label")
		return 2;
	if (!valid({lower: 3.0, upper: 7.0}) || valid({lower: 12.0, upper: null}) || !Bounds.recorded(1) || Bounds.checks != 1)
		return 1;
	return 42;
}
