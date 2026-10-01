class Base {
	public var a:Int = 1;
	public var name:String = "base";

	public function new() {}
}

class Derived extends Base {
	public var b:Int = 2;

	public function new() {
		super();
	}
}

// Declares nothing of its own: it reflects as the class it extends.
class Leaf extends Derived {
	public function new() {
		super();
	}
}

class Other {
	public var x:Float = 1.5;

	public function new() {}
}

function sortedFields(value:Dynamic):String {
	var names = Reflect.fields(value);
	names.sort(Reflect.compare);
	return names.join(",");
}

function main():Int {
	var base:Dynamic = new Base(),
		derived:Dynamic = new Derived(),
		leaf:Dynamic = new Leaf(),
		other:Dynamic = new Other();
	var record:Dynamic = {a: 1, z: "s"};
	var checks = [
		sortedFields(base) == "a,name",
		sortedFields(derived) == "a,b,name",
		sortedFields(leaf) == "a,b,name",
		sortedFields(other) == "x",
		sortedFields(record) == "a,z",
		Reflect.field(leaf, "b") == 2,
		Reflect.field(leaf, "name") == "base",
		Reflect.field(other, "x") == 1.5,
		Reflect.field(record, "z") == "s",
		Reflect.field(base, "missing") == null,
		Reflect.hasField(derived, "b"),
		!Reflect.hasField(base, "b"),
		Reflect.field(Reflect.copy(derived), "b") == 2
	];
	Reflect.setField(derived, "b", 7);
	Reflect.setField(leaf, "name", "changed");
	checks.push(Reflect.field(derived, "b") == 7);
	checks.push(Reflect.field(leaf, "name") == "changed");
	checks.push(Reflect.field(base, "name") == "base");
	for (index in 0...checks.length)
		if (!checks[index])
			return index + 1;
	return 42;
}
