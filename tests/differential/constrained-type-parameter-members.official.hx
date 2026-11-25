// Members of a value whose type is a constrained type parameter are its constraints', in the order written, as Haxe resolves
// them: a method of an interface, both of two interfaces, a field and method of a class, a structure's field.
interface Measured {
	function measure():Int;
}

interface Readable {
	function read():Int;
}

interface Writable {
	function write(value:Int):Void;
}

class Ruler implements Measured implements Readable implements Writable {
	public var length:Int;
	var stored = 0;

	public function new(length:Int)
		this.length = length;

	public function measure():Int
		return length;

	public function read():Int
		return stored;

	public function write(value:Int):Void
		stored = value;
}

class Main {
	static function measure<T:Measured>(value:T):Int return value.measure();

	static function copy<T:Readable & Writable>(from:T, to:T):Int {
		to.write(from.read() + 1);
		return to.read();
	}

	static function lengthOf<T:Ruler>(ruler:T):Int {
		ruler.length += 1;
		return ruler.length + ruler.measure();
	}

	static function x<T:{var x:Int;
	}>(point:T):Int return point.x * 2;

	static function unused<T:Measured>(value:T):Int return value.measure() + 1;

	static function main() {
		var ruler = new Ruler(3);
		Sys.println(measure(ruler));
		Sys.println(copy(ruler, new Ruler(1)));
		Sys.println(lengthOf(ruler));
		Sys.println(x({x: 4}));
	}
}
