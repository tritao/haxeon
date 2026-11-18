// A statement may leave an Int unmatched, but under a matched Int it must cover the enum element's constructors.
enum Shape {
	Circle(radius:Int);
	Square;
}

class Main {
	static function main():Void {
		var code = 1, shape = Square;
		switch [code, shape] {
			case [1, Square]:
				Sys.println("one, square");
		}
	}
}
