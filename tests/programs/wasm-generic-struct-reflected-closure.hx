class Owner {
	public function new() {}
}

struct Value {
	public var number:Int;
	public var owner:Owner;
	public function new(owner:Owner) {
		this.number = 17;
		this.owner = owner;
	}
}

class Holder {
	public var callback:Void->Value;
	public function new(callback:Void->Value) this.callback = callback;
}

class Main {
	static var owner:Owner;
	static var callback:Void->Value;
	static function read():Value return new Value(owner);
	static function readOther():Value {
		var value = new Value(owner);
		value.number = 29;
		return value;
	}

	public static function prepare():Int {
		owner = new Owner();
		callback = read;
		var holder:Dynamic = new Holder(callback);
		var reflected:Dynamic = holder.callback;
		var result:Value = cast reflected();
		if (result.owner != owner || result.number != 17) return 1;
		var replacement:Void->Value = readOther;
		holder.callback = replacement;
		var typed:Holder = cast holder;
		var updated = typed.callback();
		return updated.owner == owner && updated.number == 29 ? 42 : 2;
	}

	public static function perform(n:Int):Int {
		var operation = callback;
		var sum = 0;
		for (_ in 0...n) sum += operation().number;
		return sum;
	}

	static function main():Int {
		var result = prepare();
		if (result != 42) return result;
		#if !wasm
		var before = hl.Gc.totalAllocated();
		var sum = perform(1024);
		var allocated = hl.Gc.totalAllocated() - before;
		if (sum != 17408 || allocated != 0) {
			Sys.println('reflected closure: sum=$sum allocated=$allocated bytes');
			return 3;
		}
		#end
		return 42;
	}
}
