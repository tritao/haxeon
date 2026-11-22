// Null checks the compiler drops from whole-program facts still throw wherever Haxe does.
class Leaf {
	public var value = 1;

	public function new() {}
}

class Base {
	public var leaf:Leaf;

	public function new() {
		peek();
		leaf = new Leaf();
	}

	/** Runs before `leaf` is set: reading through it throws. */
	public function peek():Void {}

	public function read():Int
		return leaf.value;
}

class Early extends Base {
	public var seen = 0;

	override public function peek():Void {
		try {
			seen = leaf.value;
		} catch (e:Dynamic) {
			seen = -1;
		}
	}
}

class Held {
	public var leaf:Leaf;
	public var name:String;

	public function new() {
		leaf = new Leaf();
		name = "held";
	}

	public function length():Int
		return name.length + leaf.value;
}

class Lambdas {
	public var leaf = new Leaf();

	public function new() {}

	public function sum(times:Int):Int {
		var total = 0;
		var add = () -> total += leaf.value;
		for (_ in 0...times)
			add();
		return total;
	}
}

function throws(f:() -> Int):Int {
	try {
		f();
	} catch (e:Dynamic) {
		return 1;
	}
	return 0;
}

function main():Int {
	var count = 0;
	// A field read in a constructor before the field is set.
	var early = new Early();
	if (early.seen == -1)
		count++;
	if (early.read() == 1)
		count++;
	// A method called on null throws at the call, directly or through Dynamic.
	var missing:Null<Held> = null;
	count += throws(() -> missing.length());
	var dynamicMissing:Dynamic = missing;
	count += throws(() -> dynamicMissing.length());
	// Fields set non-null in the constructor, then cleared by reflection and through Dynamic.
	var held = new Held();
	if (held.length() == 5)
		count++;
	Reflect.setField(held, "leaf", null);
	count += throws(() -> held.leaf.value);
	var other = new Held();
	var view:Dynamic = other;
	view.leaf = null;
	count += throws(() -> other.leaf.value);
	count += throws(() -> other.length());
	// A lambda's environment.
	if (new Lambdas().sum(3) == 3)
		count++;
	return count * 4 + 6;
}
