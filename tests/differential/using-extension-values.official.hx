// Static extensions as Haxe applies them beyond a call: read as a function value (bound to the value, which is evaluated once),
// on a value of a type parameter through its constraints, and through `@:using` on a typedef.
using StringTools;
using Lambda;
using Main.Tools;

class Tools {
	public static function add(n:Int, by:Int = 1):Int
		return n + by;

	public static function shout(text:String):Void
		Sys.println(text.toUpperCase());

	public static function total(n:Int,...more:Int):Int {
		for (value in more)
			n += value;
		return n;
	}

	public static function describe < T:Shape > (shape:T):String return "shape " + shape.area();

	public static function doubled(shape:Shape):Int
		return shape.area() * 2;
}

interface Shape {
	function area():Int;
}

class Square implements Shape {
	public function new() {}

	public function area():Int
		return 4;
}

@:using(Main.PointTools)
typedef Point = {x:Int, y:Int};

class PointTools {
	public static function sum(point:Point):Int
		return point.x + point.y;
}

class Main {
	static var reads = 0;

	static function text():String {
		reads++;
		return "  hi  ";
	}

	static function measure < T:Shape > (value:T):String return value.describe() + " " + value.doubled();

	static function main():Void {
		var trimmed = text().trim;
		Sys.println("[" + trimmed() + "][" + trimmed() + "] " + reads);
		var three = 3;
		var increment = three.add;
		Sys.println(increment());
		var greet = "hey".shout;
		greet();
		var sum = 1.total;
		Sys.println(sum(2, 3));
		var count = [1, 2, 3].count;
		Sys.println(count());
		Sys.println(measure(new Square()));
		var point:Point = {x: 1, y: 2};
		Sys.println(point.sum());
	}
}
