// A lowercase name in a pattern captures, even where a function, a local, a static or an instance field has that name.
enum Shape {
	Box(size:Int);
	Pair(width:Int, label:String);
}

class Main {
	var width = 2;
	static var count = 9;

	function new() {}

	static function size():Int
		return 3;

	function instance():Void {
		switch (Pair(7, "w")) {
			case Pair(width, label):
				Sys.println(width + label);
			default:
		}
		Sys.println(width);
	}

	static function main():Void {
		var limit = 1;
		switch (Box(5)) {
			case Box(size):
				Sys.println(size);
			default:
		}
		switch (Box(6)) {
			case Box(limit):
				Sys.println(limit);
			default:
		}
		switch (Box(8)) {
			case Box(count):
				Sys.println(count);
			default:
		}
		switch ([4, 5]) {
			case [size, limit]:
				Sys.println(size + limit);
			default:
		}
		switch (4) {
			case limit if (limit > 3):
				Sys.println(limit);
			default:
		}
		new Main().instance();
		Sys.println(size() + limit + count);
	}
}
