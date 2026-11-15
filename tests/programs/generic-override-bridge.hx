// An override that specializes a generic base method lowers to its own signature (`Int` where the base has an erased `T`).
// Calls through the base slot, through the override's own class and through a further override all pass and return the
// specialized values intact, whatever addresses their boxes live at.
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
	if ((cast base : Child).recorded != 42)
		return 5;
	var wrapped = base.wrap(21);
	if (wrapped.length != 2 || wrapped[0] + wrapped[1] != 42)
		return 6;
	return 42;
}
