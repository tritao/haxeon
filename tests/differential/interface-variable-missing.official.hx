// A class that implements an interface has its variables: "Field x needed by Shape is missing", at the class's name.
interface Shape {
	var x:Int;
}

class Square implements Shape {
	public function new() {}
}

class Main {
	static function main() {
		var shape:Shape = new Square();
		Sys.println(shape.x);
	}
}
