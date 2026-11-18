// An interface's variables and properties, as Haxe has them: an access through the interface reaches the object's variable or
// calls its accessor, whatever class it is, and an inherited variable, an interface base's, a generic one and a function-typed
// one all work. Exits 42 when every check holds.
interface Shape {
	var x:Int;
	var area(get, never):Int;
	var label(get, set):String;
	var fixed(default, null):Float;
	final id:Int;
}

interface HasY extends HasX {
	var y(get, set):Int;
}

interface HasX {
	var x:Int;
}

interface Box<T> {
	var value:T;
	var items(default, null):Array<T>;
}

interface Callback {
	var run:Int->Int;
}

class Square implements Shape {
	public var x:Int = 1;
	public var area(get, never):Int;
	public var label(get, set):String;
	var storedLabel = "square";
	public var fixed(default, null):Float = 2.5;
	public final id:Int = 7;

	public function new() {}

	function get_area():Int
		return x * x;

	function get_label():String
		return "label:" + storedLabel;

	function set_label(value:String):String {
		storedLabel = value;
		return value + "!";
	}
}

class Base {
	public var x:Int = 1;

	public function new() {}
}

class Point extends Base implements HasY {
	public var y(get, set):Int;

	function get_y()
		return x * 2;

	function set_y(v) {
		x = v;
		return x;
	}
}

class Point3 extends Point {}

class IntBox implements Box<Int> {
	public var value:Int = 4;
	public var items(default, null):Array<Int> = [1, 2];

	public function new() {}
}

class GenericBox<T> implements Box<T> {
	public var value:T;
	public var items(default, null):Array<T> = [];

	public function new(value:T) {
		this.value = value;
		items.push(value);
	}
}

class Doubler implements Callback {
	public var run:Int->Int = n -> n * 2;

	public function new() {}
}

class Checks {
	public static var failures = 0;

	public static function equal<T>(actual:T, expected:T):Void
		if (actual != expected)
			failures++;
}

function sum(values:Array<HasX>):Int {
	var total = 0;
	for (value in values)
		total += value.x;
	return total;
}

function describe(box:Box<String>):String
	return box.value + "/" + box.items.length;

function main():Int {
	var shape:Shape = new Square();
	Checks.equal(shape.x, 1);
	shape.x = 3;
	Checks.equal(shape.area, 9);
	shape.x += 2;
	Checks.equal(shape.area, 25);
	shape.x++;
	Checks.equal(++shape.x, 7);
	Checks.equal(shape.x++, 7);
	Checks.equal(shape.x = 10, 10);
	Checks.equal(shape.label, "label:square");
	shape.label = "round";
	Checks.equal(shape.label, "label:round");
	Checks.equal(shape.label = "box", "box!");
	Checks.equal(shape.fixed, 2.5);
	Checks.equal(shape.id, 7);

	var j:HasY = new Point();
	j.x += 5;
	j.y++;
	Checks.equal(j.x, 13);
	Checks.equal(j.y, 26);
	var i:HasX = j;
	Checks.equal(i.x, 13);
	var p3 = new Point3();
	var asY:HasY = p3;
	asY.y = 21;
	Checks.equal(p3.x, 21);
	Checks.equal(sum([new Point(), p3, j]), 35);

	var box:Box<Int> = new IntBox();
	box.value *= 3;
	Checks.equal(box.value, 12);
	box.items.push(9);
	Checks.equal(box.items.length, 3);
	Checks.equal(describe(new GenericBox("text")), "text/1");
	var generic:Box<Float> = new GenericBox(1.5);
	generic.value += 1;
	Checks.equal(generic.value, 2.5);

	var callback:Callback = new Doubler();
	Checks.equal(callback.run(21), 42);
	callback.run = n -> n + 1;
	Checks.equal(callback.run(21), 22);
	return Checks.failures == 0 ? 42 : Checks.failures;
}
