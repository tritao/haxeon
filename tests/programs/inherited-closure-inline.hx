// An inherited method that captures `this` in a closure, inlined into a call on a subclass: the closure's environment
// takes the receiver as the base class. Subclass values stored where the base class is taken are upcast without a check.
interface Builder {
	function build(context:Int):Int;
}

class Base implements Builder {
	var value:Int;

	public function new(value:Int)
		this.value = value;

	public function build(context:Int):Int
		return run(function() return inner(context));

	function inner(context:Int):Int
		return value + context;

	static function run(f:Void->Int):Int
		return f();
}

class Derived extends Base implements Builder {
	public function new(value:Int)
		super(value);
}

class Leaf extends Derived {
	public function new(value:Int)
		super(value);
}

class Holder {
	public var base:Base;

	public function new() {}
}

class Main {
	static function first(items:Array<Base>):Base
		return items[0];

	static function main():Int {
		var inLambda = function(context:Int):Int return new Derived(10).build(context);
		var direct = new Leaf(20).build(2);
		var holder = new Holder();
		holder.base = new Leaf(5);
		var items:Array<Base> = [new Derived(3), new Leaf(4)];
		var builder:Builder = new Leaf(0);
		// 12 + 22 + 5 + 3 + 0 = 42
		return inLambda(2) + direct + holder.base.build(0) + first(items).build(0) + builder.build(0);
	}
}
