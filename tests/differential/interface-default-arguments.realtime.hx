// Haxe fills a parameter's default in the function that runs: a call that omits the argument passes null, and the
// function replaces null with its own default. A call through an interface or a base class gets the default of the
// implementation, never one the interface declares, and an explicit null gets the default too.
interface InterfaceDefault {
	function code(value:Int, code:String = "interface"):String;
}

interface ImplementationDefault {
	function code(value:Int, ?code:String):String;
}

interface BothDefaults {
	function code(value:Int, code:String = "interface"):String;
}

interface Counted {
	function count(?step:Int, start:Int = 3):Int;
}

interface OptionalArgument {
	function code(value:Int, ?code:String):String;
}

class InterfaceDefaultOnly implements InterfaceDefault {
	public function new() {}

	public function code(value:Int, ?code:String):String
		return value + " " + code;
}

class ImplementationDefaultOnly implements ImplementationDefault {
	public function new() {}

	public function code(value:Int, code:String = "implementation"):String
		return value + " " + code;
}

class Both implements BothDefaults {
	public function new() {}

	public function code(value:Int, code:String = "implementation"):String
		return value + " " + code;
}

class Optional implements OptionalArgument {
	public function new() {}

	public function code(value:Int, ?code:String):String
		return value + " " + code;
}

class Counter implements Counted {
	public function new() {}

	public function count(?step:Int, start:Int = 3):Int
		return start + (step == null ? 0 : step);
}

class Base {
	public function new() {}

	public function code(value:Int, code:String = "base"):String
		return value + " " + code;
}

class Derived extends Base {
	public function new() {
		super();
	}

	override public function code(value:Int, code:String = "derived"):String
		return value + " " + code;
}

class Main {
	static function label(value:Int, label:String = "static"):String
		return value + " " + label;

	static function main():Void {
		var interfaceDefault:InterfaceDefault = new InterfaceDefaultOnly();
		Sys.println("interface default: " + interfaceDefault.code(1));
		Sys.println("interface default, class receiver: " + new InterfaceDefaultOnly().code(2));
		var implementationDefault:ImplementationDefault = new ImplementationDefaultOnly();
		Sys.println("implementation default: " + implementationDefault.code(3));
		var both:BothDefaults = new Both();
		Sys.println("both defaults: " + both.code(4));
		Sys.println("both defaults, given: " + both.code(5, "given"));
		var optional:OptionalArgument = new Optional();
		Sys.println("optional argument: " + optional.code(6));
		var counted:Counted = new Counter();
		Sys.println("value default: " + counted.count() + " " + counted.count(2));
		var base:Base = new Derived();
		Sys.println("override through the base: " + base.code(7));
		Sys.println("explicit null: " + new Both().code(8, null));
		Sys.println("explicit null, static: " + label(9, null));
		Sys.exit(0);
	}
}
