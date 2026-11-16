// An override that specializes a generic base method lowers to its own signature (`Int` where the base has an erased `T`).
// Calls through the base slot, the override's own class, a further override, a generic interface, `super`, a method
// closure and Dynamic all pass and return the specialized values intact, whatever addresses their boxes live at.
interface Source<T> {
	function produce(seed:T):T;
}

class IntSource implements Source<Int> {
	public function new() {}

	public function produce(seed:Int):Int
		return seed + 2;
}

class Base<T> {
	public function new() {}

	public function connector(name:T):T
		return name;

	public function record(value:T):Void {}

	public function wrap(value:T):Array<T>
		return [value];
}

class Middle<U> extends Base<U> {
	public function new()
		super();
}

class Child extends Middle<Int> {
	public var recorded = 0;

	public function new()
		super();

	override public function connector(name:Int):Int
		return name + 1;

	override public function record(value:Int):Void
		recorded += value;

	override public function wrap(value:Int):Array<Int>
		return [value, value];
}

class GrandChild extends Child {
	public function new()
		super();

	override public function connector(name:Int):Int
		return name * 2;
}

class Chained extends Base<Int> {
	public function new()
		super();

	override public function connector(name:Int):Int
		return super.connector(name) + 1;
}

class Scale extends Base<Float> {
	public function new()
		super();

	override public function connector(name:Float):Float
		return name * 0.5;
}

function main():Int {
	var base:Base<Int> = new Child();
	if (base.connector(41) != 42 || base.connector(5000) != 5001)
		return 1;
	var child = new Child();
	if (child.connector(41) != 42)
		return 2;
	var grand:Base<Int> = new GrandChild(),
		grandChild:Child = new GrandChild();
	if (grand.connector(21) != 42 || grandChild.connector(21) != 42)
		return 3;
	var scale:Base<Float> = new Scale();
	if (scale.connector(84.0) != 42.0)
		return 4;
	base.record(40);
	base.record(2);
	if ((cast base:Child).recorded != 42)
		return 5;
	var wrapped = base.wrap(21);
	if (wrapped.length != 2 || wrapped[0] + wrapped[1] != 42)
		return 6;
	var source:Source<Int> = new IntSource();
	if (source.produce(40) != 42)
		return 7;
	var chained:Base<Int> = new Chained();
	if (chained.connector(41) != 42)
		return 8;
	var bound = child.connector, erased = base.connector;
	if (bound(41) != 42 || erased(41) != 42)
		return 9;
	var dynamicChild:Dynamic = child;
	if (dynamicChild.connector(41) != 42)
		return 10;
	return 42;
}
