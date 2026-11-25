package lib;

interface Shape {
	function area():Float;
	function name():String;
}

class Square implements Shape {
	final side:Float;

	public function new(side:Float)
		this.side = side;

	public function area():Float
		return side * side;

	public function name():String
		return "square";
}

class Circle implements Shape {
	final radius:Float;

	public function new(radius:Float)
		this.radius = radius;

	public function area():Float
		return Math.PI * radius * radius;

	public function name():String
		return "circle";
}

class Shapes {
	static var made = 0;

	public static function unit():Shape {
		made++;
		return new Square(1);
	}

	public static function check(value:Int):Void
		if (value < 0)
			throw "negative " + value + " after " + made;

	public static function describe(list:{name:String, value:Int}):String
		return list.name + " " + list.value;
}
