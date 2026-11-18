// `(value : Type)` is a type check, as in Haxe: the value unifies with the type, converts implicitly, and the expression has it.
interface Shape {
	function area():Float;
}

class Square implements Shape {
	public var side:Float;

	public function new(side:Float)
		this.side = side;

	public function area():Float
		return side * side;
}

class Base {
	public function new() {}

	public function name():String
		return "base";
}

class Derived extends Base {
	override public function name():String
		return "derived";
}

abstract Meters(Float) from Float to Float {}

class Main {
	static function maybe(flag:Bool):Null<Int>
		return flag ? 7 : null;

	static function main() {
		var empty = ([]:Array<Int>);
		empty.push(3);
		Sys.println(empty);
		var floats = ([1, 2]:Array<Float>);
		floats.push(2.5);
		Sys.println(floats);
		var missing = (null:Null<Square>);
		Sys.println(missing == null);
		var half = (3:Float) / 2;
		Sys.println(half);
		var dynamicValue:Dynamic = 5;
		var fromDynamic = (dynamicValue:Int);
		Sys.println(fromDynamic + 1);
		var toDynamic = (fromDynamic:Dynamic);
		Sys.println(toDynamic);
		var shape = (new Square(2):Shape);
		Sys.println(shape.area());
		var base = (new Derived():Base);
		Sys.println(base.name());
		var length = (2.5:Meters);
		Sys.println((length:Float) * 2);
		var optional = (maybe(true):Null<Int>);
		Sys.println(optional);
		var nothing = (maybe(false):Null<Int>);
		Sys.println(nothing);
		var callback = (function(x:Int) return x * 2:Int->Int);
		Sys.println(callback(4));
		var record = ({x: 1, y: 2}:{x:Int, y:Int});
		Sys.println(record.x + record.y);
		var widened:Array<Float> = [for (i in 0...3)(i:Float)];
		Sys.println(widened);
	}
}
