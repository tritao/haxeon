// A name in the pattern of `.match` would bind the value, and Haxe allows no pattern variables there.
enum Shape {
	Circle(radius:Int);
	Empty;
}

class Main {
	static function main():Void {
		Sys.println(Circle(1).match(shape));
	}
}
