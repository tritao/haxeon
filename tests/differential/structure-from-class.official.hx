// A class instance stands for a structure through its public fields and methods, as in Haxe.
typedef Measured = {
	final name:String;
	function area():Int;
}

class Rectangle {
	public final name = "rectangle";
	final width:Int;
	final height:Int;

	public function new(width:Int, height:Int) {
		this.width = width;
		this.height = height;
	}

	public function area():Int
		return width * height;
}

class Main {
	static function main() {
		var shape:Measured = new Rectangle(3, 4);
		Sys.println(shape.name + " " + shape.area());
	}
}
