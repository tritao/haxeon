interface Shape {
	function area():Int;
}

class Base {
	public var n:Int;

	public function new(n:Int) {
		this.n = n;
	}

	public function get():Int {
		return n;
	}

	public function twice():Int {
		return n * 2;
	}
}

// Overrides get() but inherits twice().
class Derived extends Base {
	public function new(n:Int) {
		super(n);
	}

	override public function get():Int {
		return n + 100;
	}
}

class Leaf {
	public var v:Int;

	public function new(v:Int) {
		this.v = v;
	}

	public function value():Int {
		return v;
	}
}

// Inherits value() without overriding it.
class LeafChild extends Leaf {
	public function new(v:Int) {
		super(v);
	}
}

class Square implements Shape {
	var side:Int;

	public function new(side:Int) {
		this.side = side;
	}

	public function area():Int {
		return side * side;
	}
}

function viaBase(b:Base):Int {
	return b.get() + b.twice();
}

function viaLeaf(l:Leaf):Int {
	return l.value() + 1;
}

function viaShape(s:Shape):Int {
	return s.area();
}

function main():Int {
	var failures = 0;
	if (viaBase(new Base(3)) != 3 + 6)
		failures += 1;
	if (viaBase(new Derived(3)) != 103 + 6)
		failures += 2;
	if (viaLeaf(new Leaf(5)) != 6 || viaLeaf(new LeafChild(7)) != 8)
		failures += 4;
	if (viaShape(new Square(4)) != 16)
		failures += 8;
	var total = 0;
	var items:Array<Base> = [new Base(1), new Derived(2), new Base(3)];
	for (item in items)
		total += item.get();
	if (total != 1 + 102 + 3)
		failures += 16;
	return failures == 0 ? 42 : failures;
}
