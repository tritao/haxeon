// A tuple switch used as a statement may leave values of its first decided Int or String element unmatched, as in Haxe: such a
// tuple runs no case. The values its cases name must still be covered, and so must every later element.
enum Shape {
	Circle(radius:Int);
	Square;
}

class Main {
	static function check(code:Int, label:String, shape:Shape):Void {
		switch [code, label] {
			case [1, _]:
				Sys.println("one");
			case [2, "two"]:
				Sys.println("two");
			case [2, _]:
				Sys.println("two, other");
		}
		switch [shape, code] {
			case [_, 7]:
				Sys.println("seven");
		}
		switch [code, shape] {
			case [3, Circle(_)]:
				Sys.println("three, circle");
			case [3, Square]:
				Sys.println("three, square");
		}
	}

	static function main():Void {
		check(1, "x", Square);
		check(2, "two", Circle(1));
		check(2, "zz", Square);
		check(3, "y", Circle(2));
		check(3, "y", Square);
		check(7, "seven", Square);
		check(9, "none", Square);
		Sys.println("done");
	}
}
