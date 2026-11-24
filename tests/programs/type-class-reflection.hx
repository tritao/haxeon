// Haxe's Type API on a class or enum named where it is called: names, constructors, field lists in HashLink's order, and
// construction with and without the constructor.
enum Shape {
	Circle(radius:Float);
	Square;
	Rect(w:Int, h:Int);
}

interface Named {
	function name():String;
}

class Base {
	public var a:Int = 1;
	var z:String;
	public static var bs = 3;

	public function new() {
		z = "z";
	}

	public function m():Int
		return 1;

	public function o():Int
		return 2;

	static function bstat():Int
		return 4;
}

class Child extends Base {
	public var b:Int;
	public var label:String;
	public var computed(get, never):Int;
	public var readable(default, null):Int;
	public static var sc = 1;
	static final sf = 2;

	public static function sm():Int
		return sc + sf;

	public function new(b:Int, label:String) {
		super();
		this.b = b;
		this.label = label;
		readable = 5;
	}

	public function n():Int
		return 3;

	override public function o():Int
		return 6;

	function get_computed():Int
		return b * 2;
}

class Leaf extends Child {}

class Point {
	public var x:Float;
	public var y:Float;
	public var tag:String = "initial";

	public function new(x:Float, y:Float) {
		this.x = x;
		this.y = y;
	}
}

function check(failures:Array<String>, label:String, actual:Dynamic, expected:String):Void {
	if (Std.string(actual) != expected)
		failures.push(label + ": " + Std.string(actual) + " != " + expected);
}

function main():Int {
	var failures:Array<String> = [];
	check(failures, "class name", Type.getClassName(Child), "Child");
	check(failures, "interface name", Type.getClassName(Named), "Named");
	check(failures, "String name", Type.getClassName(String), "String");
	check(failures, "enum name", Type.getEnumName(Shape), "Shape");
	check(failures, "constructs", Type.getEnumConstructs(Shape), "[Circle,Square,Rect]");
	check(failures, "base instance fields", Type.getInstanceFields(Base), "[m,o,a,z]");
	check(failures, "instance fields", Type.getInstanceFields(Child), "[n,get_computed,b,label,readable,m,o,a,z]");
	check(failures, "inherited instance fields", Type.getInstanceFields(Leaf),
		"[n,get_computed,b,label,readable,m,o,a,z]");
	check(failures, "class fields", Type.getClassFields(Child), "[sc,sf,sm]");
	check(failures, "base class fields", Type.getClassFields(Base), "[bs,bstat]");
	check(failures, "no class fields", Type.getClassFields(Leaf), "[]");
	var fields = Type.getInstanceFields(Point);
	fields.push("extra");
	check(failures, "fresh list", fields.length + " " + Type.getInstanceFields(Point).length, "4 3");
	var made = Type.createInstance(Child, [7, "made"]);
	check(failures, "createInstance", made.b + made.label + made.computed + made.a, "7made141");
	check(failures, "createInstance point", Type.createInstance(Point, [1.5, 2]).y, "2");
	var empty = Type.createEmptyInstance(Point);
	check(failures, "empty float", empty.x, "0");
	check(failures, "empty initializer not run", empty.tag == null, "true");
	empty.tag = "set";
	empty.x = 3;
	check(failures, "empty usable", empty.tag + empty.x, "set3");
	var emptyChild = Type.createEmptyInstance(Child);
	check(failures, "empty int field", emptyChild.b + emptyChild.a, "0");
	check(failures, "empty reference field", emptyChild.label == null, "true");
	check(failures, "empty methods", emptyChild.n() + emptyChild.o(), "9");
	// The Wasm parity corpus runs without a host printer: the exit code says how many checks failed.
	return failures.length == 0 ? 42 : failures.length;
}
