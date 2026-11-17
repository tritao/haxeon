// Static initialization runs in Haxe's order: every class's __init__ first, then each class's static initializers in declaration
// order. A class follows the classes its static initialization reaches (static fields, static methods and constructors, not
// instance methods); a read of a static not yet set sees its default value.
var moduleVar = say("moduleVar");

function say(text:String):Int {
	Sys.println(text);
	return 1;
}

class Main {
	static var forward = later + 1;
	static var later = 1;
	static var text = laterText + "!";
	static var laterText = "x";
	static var flag = laterFlag;
	static var laterFlag = true;
	static var ratio = laterRatio * 2;
	static var laterRatio = 1.5;
	static var constant = CONSTANT + 1;
	static inline var CONSTANT = 5;
	static var finalValue = FINAL + 1;
	static final FINAL = 7;
	static var fromOther = Provider.value + 100;
	static var fromCall = Calls.get();
	static var fromConstructor = new Built().value;
	static var fromInstanceMethod = new Plain().read();
	static var cycle = say("Main.cycle") + Cycle.c;

	static function __init__() {
		Sys.println("Main.__init__ later=" + later + " forward=" + forward);
	}

	static function main() {
		Sys.println([forward, later, constant, finalValue, fromOther, fromCall, fromConstructor, fromInstanceMethod]);
		Sys.println(text + " " + flag + " " + ratio);
		Sys.println(Cycle.c + " " + Cycle2.d + " " + cycle);
		Sys.println(Late.order);
		Sys.println(Child.child);
	}
}

class Provider {
	public static var value = say("Provider.value") + 9;

	static function __init__()
		Sys.println("Provider.__init__ value=" + value);
}

class Calls {
	public static function get():Int
		return Deep.deep * 2;
}

class Deep {
	public static var deep = say("Deep.deep") + 20;
}

class Built {
	public var value:Int;

	public function new()
		value = ByConstructor.seed;
}

class ByConstructor {
	public static var seed = say("ByConstructor.seed") + 2;
}

class Plain {
	public function new() {}

	public function read():Int
		return ByMethod.seed;
}

class Cycle {
	public static var c:Int = say("Cycle.c") + Cycle2.d;
}

class Cycle2 {
	public static var d:Int = say("Cycle2.d") + Cycle.c + 10;
}

class ByMethod {
	public static var seed = say("ByMethod.seed") + 3;
}

class Late {
	public static var order = [Second.name, First.name];
}

class Second {
	public static var name = "second";

	static function __init__()
		Sys.println("Second.__init__");
}

class First {
	public static var name = "first";
}

class Base {
	static var base = say("Base.base");
}

class Child extends Base {
	public static var child = say("Child.child");
}
