// An abstract's members are typed whether or not anything calls them, as in Haxe; these, which nothing calls, are valid.
abstract Box<T>(Array<T>) from Array<T> {
	public inline function new(values:Array<T>)
		this = values;

	public function first():T
		return this[0];

	public function both():Array<T>
		return [first(), first()];

	public function mapped<U>(f:T->U):Array<U>
		return [for (value in this) f(value)];

	@:to function toArray():Array<T>
		return this;

	@:arrayAccess function get(index:Int):T
		return this[index];
}

abstract Celsius(Float) from Float {
	public function new(value:Float)
		this = value;

	public function fahrenheit():Float
		return this * 9 / 5 + 32;

	public function label():String {
		var parts = [];
		parts.push(Std.string(this));
		parts.push("C");
		return parts.join("");
	}

	public function record():{value:Float, unit:String} return {value: this, unit: "C"};

	@:op(A > B) static function greater(a:Celsius, b:Celsius):Bool
		return (cast a:Float) > (cast b:Float);
}

class Main {
	static function main() {
		var box:Box<Int> = [3, 4];
		Sys.println(box.first());
		var c:Celsius = 21.5;
		Sys.println(c.fahrenheit());
	}
}
