interface Named {
	function value():Int;
}

class Base {
	public var base:Int = 5;
	public var flag:Null<Bool>;

	public function new() {}
}

class Child extends Base implements Named {
	public static var constructors:Int = 0;

	public var items:Array<Int>;

	public function new() {
		super();
		constructors++;
		items = [7];
	}

	public function value():Int
		return base + items[0];
}

function main():Int {
	var original = new Child();
	var originalNamed:Named = original;
	if (originalNamed.value() != 12)
		return 1;
	var copied:Child = cast Reflect.copy(original);
	if (copied == original || Child.constructors != 1 || copied.value() != 12 || copied.flag != null)
		return 2;
	copied.base = 9;
	copied.items[0] = 8;
	if (original.base != 5 || original.items[0] != 8)
		return 3;
	var copiedNamed:Named = copied;
	return copiedNamed.value() == 17 && Child.constructors == 1 ? 42 : 4;
}
