// A class without a constructor has its base class's, so constructing it runs the whole chain.

class Base {
	public final items:Array<Int> = [1, 2, 3];

	public function new() {}
}

class Derived extends Base {
	public var extra = 10;
}

class Named {
	public final name:String;
	public final size:Int;
	public var seen = 0;

	public function new(name:String, size:Int) {
		this.name = name;
		this.size = size;
		seen = size;
	}
}

class Child extends Named {
	public var tag = 5;
}

class Grandchild extends Child {}

class Box<T> {
	public var value:T;

	public function new(value:T) {
		this.value = value;
	}
}

class IntBox extends Box<Int> {
	public var doubled = 2;
}

class Optional {
	public final amount:Int;

	public function new(?amount:Int = 7) {
		this.amount = amount;
	}
}

class OptionalChild extends Optional {}

class OnlyInitializers {
	public final numbers:Array<Int> = [4, 5];
}

class FromInitializers extends OnlyInitializers {
	public final more:Array<Int> = [6];
}

function main():Int {
	var derived = new Derived();
	if (derived.items.length != 3 || derived.extra != 10)
		return 1;

	var grandchild = new Grandchild("gc", 4);
	if (grandchild.name != "gc" || grandchild.size != 4 || grandchild.seen != 4 || grandchild.tag != 5)
		return 2;

	var box = new IntBox(41);
	if (box.value + 1 != 42 || box.doubled != 2)
		return 3;

	var optional = new OptionalChild();
	if (optional.amount != 7 || new OptionalChild(3).amount != 3)
		return 4;

	var initializers = new FromInitializers();
	if (initializers.numbers.length != 2 || initializers.more.length != 1)
		return 5;

	return 42;
}
