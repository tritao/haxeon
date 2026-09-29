abstract Millimetres(Float) from Float to Float {
	public inline function new(value:Float)
		this = value;

	@:op(A + B) public static function add(a:Millimetres, b:Millimetres):Millimetres
		return new Millimetres((a : Float) + (b : Float));

	@:op(A * B) public static function multiply(a:Millimetres, factor:Float):Millimetres
		return new Millimetres((a : Float) * factor);

	@:op(A < B) public static function less(a:Millimetres, b:Millimetres):Bool
		return (a : Float) < (b : Float);
}

class Main {
	static function main():Void {
		var a = new Millimetres(2.0);
		var b = new Millimetres(3.0);
		if ((a + b : Float) != 5.0 || (a * 4.0 : Float) != 8.0 || !(a < b))
			throw "abstract operator result mismatch";
	}
}
