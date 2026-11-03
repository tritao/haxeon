struct Inner {
	public var tag:UInt8;
	public var delta:Int16;
	public function new(tag:Int, delta:Int) { this.tag = cast tag; this.delta = cast delta; }
}

struct Outer {
	public var prefix:UInt8;
	public var child:Inner;
	public var tail:Int;
	public function new() { prefix = 1; child = new Inner(250, -1234); tail = 42; }
}

class Holder {
	public var value:Outer;
	public function new() value = new Outer();
}

class Owner {
	public var id:Int;
	public function new(id:Int) this.id = id;
}

struct Mixed {
	public var marker:UInt8;
	public var owner:Owner;
	public var flat:Outer;
	public var last:UInt8;
	public function new(owner:Owner) { marker = 9; this.owner = owner; flat = new Outer(); last = 7; }
}

class MixedHolder {
	public var value:Mixed;
	public function new(owner:Owner) value = new Mixed(owner);
}

class Inspect {
	static var retained:MixedHolder;
	public static function make():Holder return new Holder();
	public static function makeMixed():MixedHolder {
		retained = new MixedHolder(new Owner(73));
		return retained;
	}
	public static function checkMixed():Int {
		for (index in 0...512) {
			var transient = new Owner(index);
			if (transient.id != index) return 1;
		}
		return retained.value.owner.id;
	}
}

class Census {
	static var retained:Array<Holder>;
	public static function prepare(n:Int):Void retained = new Array<Holder>(n);
	public static function construct(n:Int):Int {
		var sum = 0;
		for (index in 0...n) {
			var holder = new Holder();
			retained[index] = holder;
			sum += holder.value.tail;
		}
		return sum;
	}
}

function main():Int {
	if (sizeof<Inner>() != 4 || alignof<Inner>() != 2 || offsetof<Outer>("child") != 2
		|| offsetof<Outer>("tail") != 8 || sizeof<Outer>() != 12) return 8;
	var erased:Dynamic = new Outer();
	var extracted:Outer = cast erased;
	if ((cast extracted.prefix:Int) != 1 || (cast extracted.child.tag:Int) != 250
		|| (cast extracted.child.delta:Int) != -1234 || extracted.tail != 42) return 1;
	var holder = new Holder();
	var copy = holder.value;
	holder.value.child.tag = cast 259;
	holder.value.child.delta = cast 65535;
	if ((cast holder.value.child.tag:Int) != 3 || (cast holder.value.child.delta:Int) != -1) return 2;
	if ((cast copy.child.tag:Int) != 250 || (cast copy.child.delta:Int) != -1234 || holder.value.tail != 42) return 3;
	var mixed = Inspect.makeMixed();
	if (Inspect.checkMixed() != 73 || mixed.value.flat.tail != 42 || (cast mixed.value.last:Int) != 7) return 4;
	var erasedNull:Dynamic = null;
	var missing:Holder = cast erasedNull;
	var caught = false;
	try { var unused = missing.value; if (unused.tail == 42) return 5; } catch (_:Dynamic) caught = true;
	if (!caught) return 6;
	caught = false;
	try missing.value.tail = 1 catch (_:Dynamic) caught = true;
	if (!caught) return 7;
	return 42;
}
