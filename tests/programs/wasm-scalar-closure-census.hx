class ClosureOwner {
	public var number:Int;
	public function new(number:Int) this.number = number;
}

struct ClosureValue {
	public var number:Int;
	public var owner:ClosureOwner;
	public function new(number:Int, owner:ClosureOwner) { this.number = number; this.owner = owner; }
}

class ClosureBox<T> {
	public var value:T;
	public function new(value:T) this.value = value;
	public function get():T return value;
}

class ClosureCensus {
	static var owner:ClosureOwner;
	static var read:Void->ClosureValue;
	static var number:ClosureValue->Int;
	static function extract(value:ClosureValue):Int return value.number + value.owner.number;
	public static function prepare():Void {
		owner = new ClosureOwner(4);
		var box = new ClosureBox<ClosureValue>(new ClosureValue(7, owner));
		read = box.get;
		number = extract;
	}
	public static function perform(n:Int):Int {
		var total = 0, callRead = read, callNumber = number;
		for (_ in 0...n) {
			var value = callRead();
			if (value.owner != owner) return -1;
			total += callNumber(value);
		}
		return total;
	}
	@:expose public static function expose():Void->ClosureValue return read;
	@:keep public static function retained(fn:Void->ClosureValue):Int return fn().number;
	public static function apply(fn:Void->ClosureValue):Int {
		var value = fn();
		return value.number + value.owner.number;
	}
	public static function isMissing(fn:Void->ClosureValue):Bool return fn == null;
	public static function exposeNumber():ClosureValue->Int return number;
	public static function applyNumber(fn:ClosureValue->Int):Int return fn(new ClosureValue(7, owner));
	public static function stress(n:Int):Int {
		var total = 0, callRead = read, callNumber = number;
		for (index in 0...n) {
			var value = callRead();
			var pressure = new ClosureOwner(index);
			if (value.owner != owner) return -1;
			total += callNumber(value) + pressure.number;
		}
		return total;
	}
}
function main():Int { ClosureCensus.prepare(); return ClosureCensus.perform(4) == 44 ? 42 : 1; }
