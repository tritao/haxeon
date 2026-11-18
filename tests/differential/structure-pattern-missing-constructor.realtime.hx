// A structure pattern's enum field is covered constructor by constructor: Square is unmatched.
enum Shape {
	Circle(radius:Int);
	Square;
}

class Main {
	static function main():Void {
		var item = {count: 1, shape: Square};
		switch item {
			case {
				shape:Circle(_)
			}
			: Sys.println("circle");
		}
	}
}
