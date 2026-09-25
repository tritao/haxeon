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

// A loop over a known Array<Int>/Map<K, V> is pure: it runs the runtime iterator, never user code.
function sumArray(values:Array<Int>):Int {
	var total = 0;
	for (value in values)
		total += value;
	return total;
}

function sumMap(values:Map<String, Int>):Int {
	var total = 0;
	for (value in values)
		total += value;
	return total;
}

class Counter {
	public var total:Int;

	public function new(total:Int)
		this.total = total;

	public function isPositive():Bool
		return total > 0;
}

// A method called on a parameter whose declared type is a known class resolves like a call
// through `this`, instead of unconditionally losing narrowing.
function countedValid(limits:Limits, counter:Counter):Bool
	return limits.lower != null && counter.isPositive() && limits.lower < 10;

class Shape {
	public function new() {}

	public function area():Float
		return 0.0;
}

class Circle extends Shape {
	var radius:Float;

	public function new(radius:Float) {
		super();
		this.radius = radius;
	}

	override public function area():Float
		return radius * radius * 3.14159;
}

// Base.area is overridden, but every override (here, only Circle.area) is also pure, so a call
// through the base class keeps narrowing rather than being excluded outright.
function shapeValid(limits:Limits, shape:Shape):Bool
	return limits.lower != null && shape.area() >= 0 && limits.lower < 10;

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
	if (sumArray([1, 2, 3]) != 6 || sumMap(["a" => 1, "b" => 2]) != 3)
		return 3;
	if (!countedValid({lower: 2.0, upper: null}, new Counter(1)) || countedValid({lower: 2.0, upper: null}, new Counter(0)))
		return 4;
	if (!shapeValid({lower: 2.0, upper: null}, new Circle(2.0)) || !shapeValid({lower: 2.0, upper: null}, new Shape()))
		return 5;
	return 42;
}
