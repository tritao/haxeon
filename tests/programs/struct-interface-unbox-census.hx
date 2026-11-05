interface Readable {
	function read():Int;
}

class Anchor {
	public var value:Int;
	public function new(value:Int) this.value = value;
}

struct Value implements Readable {
	public var scalar:Int;
	public var owner:Anchor;
	public function new(scalar:Int, owner:Anchor) {
		this.scalar = scalar;
		this.owner = owner;
	}
	public function read():Int return scalar + owner.value;
}

class InterfaceUnboxCensus {
	static var view:Dynamic;
	public static function prepare():Void {
		var value:Readable = new Value(17, new Anchor(25));
		view = value;
	}
	public static function perform(count:Int):Int {
		var total = 0;
		for (_ in 0...count) {
			var value:Value = cast view;
			total += value.scalar + value.owner.value;
		}
		return total;
	}
}

function main():Int {
	InterfaceUnboxCensus.prepare();
	hl.Gc.major();
	InterfaceUnboxCensus.perform(1);
	for (count in [8, 1024]) {
		#if !wasm
		var before = hl.Gc.totalAllocated();
		#end
		if (InterfaceUnboxCensus.perform(count) != 42 * count) return 1;
		#if !wasm
		if (hl.Gc.totalAllocated() != before) return 2;
		#end
	}
	return 42;
}
