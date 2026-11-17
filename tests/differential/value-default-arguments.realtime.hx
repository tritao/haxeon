// A value-type parameter with a default (`x:Int = 7`) is filled by the method that runs, as Haxe does on HashLink: an
// interface, virtual or Dynamic call gets the implementation's default, never the interface's, while a call whose
// target is known statically (static, super, final) gets that target's own. Int, Float, Bool, enum and enum abstract
// defaults, on plain and generic classes.
interface Counted {
	function count(start:Int = 3):Int;
}

class Counter implements Counted {
	public function new() {}

	public function count(start:Int = 7):Int
		return start;
}

enum Color {
	Red;
	Green;
}
enum abstract Level(Int) {
	var Low = 1;
	var High = 2;
}
interface Shape {
	function area(scale:Float = 1.5, round:Bool = false, color:Color = Red, level:Level = Low):String;
}
class Square implements Shape {
	public function new() {}
	public function area(scale:Float = 2.5, round:Bool = true, color:Color = Green, level:Level = High):String
		return scale + " " + round + " " + color + " " + level;
}
class Box<T> {
	public var v:T;
	public function new(v:T) this.v = v;
	public function get(times:Int = 2):String return v + "x" + times;
}
class Sub extends Square {
	override public function area(scale:Float = 9.5, round:Bool = false, color:Color = Red, level:Level = Low):String
		return "sub " + super.area() + " / " + super.area(1.0);
	public inline function quick(n:Int = 3):Int return n * 2;
}
class Fin {
	public function new() {}
	public function h(n:Int = 11):Int return n;
}
class Main {
	static function st(a:Int, b:Int = 10):Int return a + b;
	static function main() {
		var s:Shape = new Square();
		Sys.println(s.area());
		Sys.println(s.area(3.0));
		Sys.println(new Square().area());
		var t:Shape = new Sub();
		Sys.println(t.area());
		Sys.println(new Sub().quick() + " " + new Sub().quick(5));
		Sys.println(new Box<String>("b").get() + " " + new Box<Int>(4).get(3));
		Sys.println(new Fin().h() + " " + new Fin().h(1));
		var f = st;
		Sys.println(f(1, 2));
		var d:Dynamic = new Square();
		Sys.println(d.area(4.0, false, Green, High));
		var arr = [1, 2, 3].map(x -> st(x));
		Sys.println(arr);
		var counted:Counted = new Counter();
		Sys.println("interface default: " + counted.count() + " " + counted.count(1) + " " + new Counter().count());
		Sys.exit(0);
	}
}
