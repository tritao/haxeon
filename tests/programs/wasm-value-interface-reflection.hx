interface Readable {
	function read():Int;
}

class Owner {
	public function new() {}
}

struct Value implements Readable {
	public var x:Int;
	public var owner:Owner;
	public function new(x:Int, owner:Owner) {
		this.x = x;
		this.owner = owner;
	}
	public function read():Int return x;
	public function twice():Int return x * 2;
}

function main():Int {
	var owner = new Owner();
	var raw:Dynamic = new Value(3, owner);
	if (raw.x != 3 || raw.read() != 3 || raw.twice() != 6) return 1;
	raw.x = 5;
	if (raw.x != 5 || raw.owner != owner) return 2;
	var boxed:Readable = cast raw;
	var view:Dynamic = boxed;
	if (view.x != 5 || view.read() != 5 || view.twice() != 10) return 3;
	if (Reflect.hasField(view, "value") || !Reflect.hasField(view, "x")) return 4;
	view.x = 7;
	if (boxed.read() != 7 || raw.x != 5 || view.owner != owner) return 5;
	return 42;
}
