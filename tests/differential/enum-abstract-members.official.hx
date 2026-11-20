// An enum abstract is an abstract that also declares values: it has methods (inline ones too), properties, statics with
// metadata and operators, its values number and name themselves, and a value receives calls as any value of it does.
enum abstract Color(Int) from Int to Int {
	var Red;
	var Green = 5;
	final Blue;
	var Typed:Color = 9;
	@:noCompletion static final names = ["Red", "Green", "Blue"];
	static var created = 0;
	public static final all = [Red, Green, Blue];

	public var doubled(get, never):Int;

	function get_doubled()
		return this * 2;

	public inline function isRed():Bool
		return (cast this:Color) == Red;

	public function label():String
		return switch (cast this:Color) {
			case Red: names[0];
			case Green: names[1];
			case Blue: names[2];
			case Typed: "Typed";
			case _: "other";
		};

	public static function make(i:Int):Color {
		created++;
		return i;
	}

	public static function count():Int
		return created;

	@:op(A + B) static function add(a:Color, b:Int):Color
		return (a:Int) + b;
}

// Another abstract declaring a value of the same name: in Color's own code, Color's wins.
enum abstract Light(Int) to Int {
	var Red = 10;
	var Off;
}

enum abstract Kind(String) to String {
	var Alpha;
	var Beta = "b";

	public function upper():String
		return this.toUpperCase();

	@:from static function fromBool(b:Bool):Kind
		return b ? Alpha : Beta;
}

enum abstract Opt(Int) {
	var A;
	var B;
	var C;
}

class Main {
	static function name(o:Opt):String
		return switch o {
			case A: "a";
			case B: "b";
			case C: "c";
		};

	static function main() {
		var c = Color.Red;
		Sys.println(c.isRed() + " " + Green.doubled + " " + c.label() + " " + Blue.label() + " " + Color.Typed.label());
		var m = Color.make(5);
		Sys.println(m.label() + " " + Color.count() + " " + (Color.Red + 6).label() + " " + Color.all.length);
		var i:Int = Typed;
		Sys.println(i + " " + (Light.Red:Int) + " " + (Light.Off:Int));
		var k:Kind = true;
		Sys.println(k.upper() + " " + Beta.upper() + " " + (Alpha:String));
		Sys.println(name(A) + name(B) + name(C));
	}
}
