import haxe.ds.Option;

enum Step {
	Move(n:Int);
	Stop;
}

class Lib {
	public static function count() return 41;

	public static function annotated():Float return 1.5;
}

function moduleValue() return "module";

class Main {
	static var fromMethod = Lib.count() + 1;
	static var fromAnnotated = Lib.annotated() * 2;
	static var fromModule = moduleValue();
	static final start = Some(Move(1));
	static final steps = [Move(2), Stop];

	static function main() {
		var a:Int = fromMethod;
		var b:Float = fromAnnotated;
		var c:String = fromModule;
		Sys.println(a);
		Sys.println(b);
		Sys.println(c);
		switch start {
			case Some(Move(n)): Sys.println(n);
			case _: Sys.println("other");
		}
		Sys.println(steps.length);
	}
}
