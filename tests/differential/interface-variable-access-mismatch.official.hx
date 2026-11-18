// A class's variable has an access that unifies with the interface's: a read-only one does not implement a variable
// ("Field x has different property access than in Shape ((default,null) should be var)").
interface Shape {
	var x:Int;
}

class Square implements Shape {
	public var x(default, null):Int = 1;

	public function new() {}
}

class Main {
	static function main() {
		var shape:Shape = new Square();
		Sys.println(shape.x);
	}
}
