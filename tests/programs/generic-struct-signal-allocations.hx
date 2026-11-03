import haxeon.reactive.Signal;

class SignalAnchor {
	public final id:Int;
	public function new(id:Int) this.id = id;
}

struct SignalValue implements Equatable {
	public final number:Int;
	public final anchor:SignalAnchor;
	public function new(number:Int, anchor:SignalAnchor) {
		this.number = number;
		this.anchor = anchor;
	}
	public function equals(other:SignalValue):Bool return number == other.number && anchor == other.anchor;
}

class SignalCensus {
	static var anchor:SignalAnchor;
	static var signal:Signal<SignalValue>;
	public static function prepare():Void {
		anchor = new SignalAnchor(7);
		signal = new Signal<SignalValue>(new SignalValue(0, anchor));
	}
	public static function perform(n:Int):Int {
		var total = 0;
		for (i in 0...n) {
			signal.value = new SignalValue(i, anchor);
			var value = signal.value;
			if (value.anchor != anchor) return -1;
			total += value.number;
		}
		return total;
	}
}

function main():Int {
	SignalCensus.prepare();
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	var result = SignalCensus.perform(1024);
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 2;
	#end
	return result == 523776 ? 42 : 1;
}
