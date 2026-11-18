// An interface's variables and properties, as Haxe has them: an access through the interface reaches the object's variable or
// calls its accessor, whatever class it is (`=`, `+=`, `++` and their values), and an inherited variable, an interface base's, a
// generic one and a function-typed one all work.
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

class Main {
	static function sum(values:Array<HasX>):Int {
		var total = 0;
		for (value in values)
			total += value.x;
		return total;
	}

	static function describe(box:Box<String>):String
		return box.value + "/" + box.items.length;

	static function main() {
		var shape:Shape = new Square();
		Sys.println(shape.x);
		shape.x = 3;
		Sys.println(shape.area);
		shape.x += 2;
		Sys.println(shape.area);
		shape.x++;
		Sys.println(++shape.x);
		Sys.println(shape.x++);
		Sys.println(shape.x = 10);
		Sys.println(shape.x += 1);
		Sys.println(shape.label);
		shape.label = "round";
		Sys.println(shape.label);
		Sys.println(shape.label = "box");
		Sys.println(shape.label += "?");
		Sys.println(shape.fixed);
		Sys.println(shape.id);

		var j:HasY = new Point();
		j.x += 5;
		j.y++;
		Sys.println(j.x);
		Sys.println(j.y);
		var i:HasX = j;
		Sys.println(i.x);
		var p3 = new Point3();
		var asY:HasY = p3;
		asY.y = 21;
		Sys.println(p3.x);
		Sys.println(sum([new Point(), p3, j]));

		var box:Box<Int> = new IntBox();
		box.value *= 3;
		Sys.println(box.value);
		box.items.push(9);
		Sys.println(box.items);
		Sys.println(describe(new GenericBox("text")));
		var generic:Box<Float> = new GenericBox(1.5);
		generic.value += 1;
		Sys.println(generic.value);

		var callback:Callback = new Doubler();
		Sys.println(callback.run(21));
		callback.run = n -> n + 1;
		Sys.println(callback.run(21));
	}
}
