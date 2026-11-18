// A name in a constructor argument of a `.match` pattern is a pattern variable too, which Haxe rejects.
enum Shape {
	Circle(radius:Int);
	Empty;
}

class Main {
	static function main():Void {
		Sys.println(Circle(1).match(Circle(radius)));
	}
}
