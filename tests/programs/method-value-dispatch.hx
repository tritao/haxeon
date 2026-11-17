// A method value binds the method of its receiver's class, as Haxe does: the subclass's override with its own defaults, the
// class implementing an interface, and a value taken on `this` in the base class. Two values of one method of one object are equal.
class Base {
	public function new() {}

	public function name():String
		return "base";

	public function scaled(value:Int, ?factor:Int = 2):Int
		return value * factor;

	public function own():Void->String
		return name;
}

class Derived extends Base {
	public function new() {
		super();
	}

	override public function name():String
		return "derived";

	override public function scaled(value:Int, ?factor:Int = 3):Int
		return value * factor + 1;
}

interface Named {
	function label():String;
}

class Tag implements Named {
	public function new() {}

	public function label():String
		return "tag";
}

class Box<T> {
	final value:T;

	public function new(value:T)
		this.value = value;

	public function get():T
		return value;
}

function main():Int {
	var base:Base = new Derived(),
		name = base.name,
		scaled = base.scaled,
		named:Named = new Tag(),
		label = named.label,
		get = new Box("boxed").get;
	if (name() != "derived" || base.own()() != "derived" || label() != "tag" || get() != "boxed")
		return 1;
	if (scaled(10) != 31 || scaled(10, 5) != 51)
		return 2;
	if (!Reflect.compareMethods(base.name, base.name) || Reflect.compareMethods(base.name, new Derived().name))
		return 3;
	if (new Base().name() != "base" || (new Base().name)() != "base")
		return 4;
	return 42;
}
