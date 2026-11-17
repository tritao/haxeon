// Haxe's optional arguments: `?x` and a default are separate, and `?x:Int = 7` is `Null<Int>` while `x:Int = 7` is `Int`.
// A method's optional flags must match the ones it overrides or implements, and a `?x` default fills in the method that
// runs, through a class, an interface or a base class receiver.
interface Counter {
	function count(?step:Int):Int;
}

class StepCounter implements Counter {
	public function new() {}

	public function count(?step:Int = 7):Int
		return step;
}

class Base {
	public function new() {}

	public function label(value:Int, ?suffix:String):String
		return value + " " + suffix;
}

class Derived extends Base {
	public function new() {
		super();
	}

	override public function label(value:Int, ?suffix:String = "derived"):String
		return value + "/" + suffix;
}

class Main {
	static function cleared(?value:Int = 3):String {
		var before = value;
		value = null;
		return before + " " + value;
	}

	static function main():Void {
		var counter:Counter = new StepCounter();
		Sys.println("interface ?step, class default: " + counter.count() + " " + counter.count(2) + " "
			+ counter.count(null));
		Sys.println("class receiver: " + new StepCounter().count() + " " + new StepCounter().count(4));
		var base:Base = new Derived();
		Sys.println("override adds a default: " + base.label(1) + " " + base.label(2, "given"));
		Sys.println("nullable default: " + cleared() + " / " + cleared(5));
		Sys.exit(0);
	}
}
