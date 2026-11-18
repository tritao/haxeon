// A capture `name = pattern` in a `.match` pattern binds a pattern variable, which Haxe rejects.
enum Shape {
	Circle(radius:Int);
	Empty;
}

class Main {
	static function main():Void {
		Sys.println(Circle(1).match(shape = Circle(_)));
	}
}
