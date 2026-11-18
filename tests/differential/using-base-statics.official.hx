// `using` brings the named class's own statics only: a base class's statics are not extensions through it.
using Main.Derived;

class Base {
	public static function baseOnly(s:String):String
		return "base";
}

class Derived extends Base {
	public static function own(s:String):String
		return "derived";
}

class Main {
	static function main():Void {
		Sys.println("x".own());
		Sys.println("x".baseOnly());
	}
}
