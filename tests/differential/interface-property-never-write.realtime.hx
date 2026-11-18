// Through an interface, a property's sides are the interface's: a `never` side cannot be written, even when the class's can.
interface Shape {
	var area(get, never):Int;
}

class Square implements Shape {
	public var area(get, set):Int;

	public function new() {}

	function get_area()
		return 1;

	function set_area(value:Int)
		return value;
}

class Main {
	static function main() {
		var shape:Shape = new Square();
		shape.area = 2;
	}
}
