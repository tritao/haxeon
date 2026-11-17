// An abstract's `from` and `to` conversions as Haxe unifies them: where the other side is not an abstract (Int, Float, a
// class), an Int meets a Float and a class its base class or interface, through `from`/`to` types and `@:from`/`@:to`
// functions alike, and `(value : Type)` converts as an assignment does.
abstract Root(Float) from Float to Float {
	public function sqrt():Float
		return Math.sqrt(this);
}

abstract Meters(Float) {
	inline function new(value:Float)
		this = value;

	@:from static function fromFloat(value:Float):Meters
		return new Meters(value * 2);

	@:to function toFloat():Float
		return this + 0.5;
}

abstract Count(Int) to Int {
	public function new(value:Int)
		this = value;
}

abstract Word(String) {
	public function new(text:String)
		this = text;

	@:to function length():Int
		return this.length;
}

abstract Scaled(Float) {
	public function get():Float
		return this;
}

abstract Unscaled(Float) from Float {
	@:to function scaled():Scaled
		return cast(this * 3);
}

interface Named {
	function name():String;
}

class Base implements Named {
	public function new() {}

	public function name():String
		return "base";
}

class Derived extends Base {
	override public function name():String
		return "derived";
}

abstract Holder(Base) from Base {
	public function describe():String
		return "held " + this.name();
}

abstract Tag(Named) from Named {
	public function describe():String
		return "tag " + this.name();
}

class Main {
	static function half(value:Float):Float
		return value / 2;

	static function root(value:Int):Root
		return value;

	static function main() {
		var literal:Root = 81;
		Sys.println(literal.sqrt());
		var count = 16;
		var fromLocal:Root = count;
		Sys.println(fromLocal.sqrt());
		Sys.println(root(25).sqrt());
		var roots:Array<Root> = [1, 2.5];
		Sys.println(roots[0].sqrt() + roots[1]);
		var asFloat:Float = literal;
		Sys.println(asFloat);
		var meters:Meters = 3;
		Sys.println((meters:Float));
		var fromInt:Meters = count;
		var read:Float = fromInt;
		Sys.println(read);
		Sys.println(half(meters));
		var items = new Count(7);
		var widened:Float = items;
		Sys.println(widened);
		Sys.println(half(items));
		var word = new Word("abcd");
		var size:Float = word;
		Sys.println(size);
		Sys.println(half(word));
		var unscaled:Unscaled = 2;
		var scaled:Scaled = unscaled;
		Sys.println(scaled.get());
		var holder:Holder = new Derived();
		Sys.println(holder.describe());
		var tag:Tag = new Derived();
		Sys.println(tag.describe());
	}
}
