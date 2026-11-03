import haxeon.ui.core.BuildContext;
import haxeon.ui.core.State;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.WidgetId;

class StateAllocationAnchor {
	public final value:Int;
	public function new(value:Int) this.value = value;
}

struct StateAllocationValue : Equatable {
	public final number:Int;
	public final anchor:StateAllocationAnchor;
	public function new(number:Int, anchor:StateAllocationAnchor) {
		this.number = number;
		this.anchor = anchor;
	}
	public function equals(other:StateAllocationValue):Bool return number == other.number && anchor == other.anchor;
}

class StateAllocationCensus {
	static var anchor:StateAllocationAnchor;
	static var state:State<StateAllocationValue>;
	public static function prepare():Void {
		anchor = new StateAllocationAnchor(7);
		var build = new BuildContext(new StateStore());
		state = build.state(new WidgetId(1), new StateAllocationValue(0, anchor));
	}
	public static function perform(n:Int):Int {
		var total = 0;
		for (i in 0...n) {
			state.value = new StateAllocationValue(i, anchor);
			var value = state.value;
			if (value.anchor != anchor) return -1;
			total += value.number;
		}
		return total;
	}
}

function main():Int {
	StateAllocationCensus.prepare();
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	var result = StateAllocationCensus.perform(1024);
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 2;
	#end
	return result == 523776 ? 42 : 1;
}
