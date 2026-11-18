// Static extensions as Haxe resolves them: a value's own members first, then its type's `@:using` (a class's own, then its base
// class's), then the module's `using`, the last one first.
using StringTools;
using Lambda;
using Main.Tools;
using Main.Later;

class Tools {
	public static function double(x:Int):Int
		return x * 2;

	public static function shout(s:String):String
		return s.toUpperCase() + "!";

	public static function describe(s:String):String
		return "Tools:" + s;

	public static function isMissing(s:Null<String>):Bool
		return s == null;

	public static function sum(values:Array<Int>):Int {
		var total = 0;
		for (value in values)
			total += value;
		return total;
	}

	public static function firstOr<T>(values:Array<T>, fallback:T):T
		return values.length > 0 ? values[0] : fallback;

	public static function label(point:{x:Int, y:Int}):String
		return point.x + "," + point.y;

	public static function dyn(value:Dynamic):String
		return "dyn:" + Std.string(value);

	public static function plusOne(x:Int):Int
		return x + 1;

	// Own members win over an extension of the same name.
	public static function toUpperCase(s:String):String
		return "never";

	public static function own(point:Point):String
		return "extension";
}

class Later {
	// The later `using` is tried first.
	public static function describe(s:String):String
		return "Later:" + s;
}

class Point {
	public var x:Int;

	public function new(x:Int)
		this.x = x;

	public function own():String
		return "own";
}

abstract Meters(Int) from Int to Int {
	public function new(value:Int)
		this = value;

	public function value():Int
		return this;
}

class MeterTools {
	public static function feet(meters:Meters):Float
		return (meters:Int) * 3.25;

	public static function value(meters:Meters):Int
		return -1;
}

@:using(Main.ShapeTools)
enum Shape {
	Circle(radius:Int);
	Square(side:Int);
}

class ShapeTools {
	public static function area(shape:Shape):Int
		return switch shape {
			case Circle(radius): 3 * radius * radius;
			case Square(side): side * side;
		};
}

@:using(Main.AnimalTools)
class Animal {
	public function new() {}
}

class Dog extends Animal {
	public function new()
		super();
}

class AnimalTools {
	public static function speak(animal:Animal):String
		return "...";
}

class Main {
	static function main():Void {
		Sys.println(3.double());
		Sys.println("hi".shout());
		Sys.println("x".describe());
		Sys.println("abc".toUpperCase());
		Sys.println("  pad ".trim() + "|");
		Sys.println("abc".startsWith("ab"));
		Sys.println(255.hex());
		Sys.println("x".lpad("0", 4));
		Sys.println([1, 2, 3].sum());
		Sys.println([7, 8].firstOr(0));
		Sys.println(([]:Array<String>).firstOr("none"));
		Sys.println([1, 2, 3].has(2));
		Sys.println([1, 2, 3].count(x -> x > 1));
		Sys.println([3, 1, 4].fold((x, total) -> x + total, 0));
		Sys.println([3, 1, 4].map(x -> x * 2));
		Sys.println([3, 1, 4].filter(x -> x > 2));
		var counts = ["a" => 2, "b" => 3];
		Sys.println(counts.fold((x, total) -> x + total, 0));
		Sys.println({x: 1, y: 2}.label());
		var missing = counts.exists("z") ? "found" : null;
		Sys.println(missing.isMissing());
		Sys.println("here".isMissing());
		var maybe:Null<Int> = 4;
		Sys.println(maybe.plusOne());
		var anything:Dynamic = 5;
		Sys.println(anything.dyn());
		Sys.println(7.dyn());
		Sys.println(new Point(1).own());
		Sys.println(new Meters(2).value());
		Sys.println(MeterTools.feet(new Meters(2)));
		Sys.println(Circle(2).area());
		Sys.println(Square(3).area());
		Sys.println(new Dog().speak());
	}
}
