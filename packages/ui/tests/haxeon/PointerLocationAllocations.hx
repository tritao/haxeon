import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;

class PointerAllocationCensus {
	static var dispatcher:EventDispatcher;
	public static function prepare():Void {
		dispatcher = new EventDispatcher(new FocusManager());
		dispatcher.pointerMove(1.0, 1.0);
	}
	public static function perform(n:Int):Int {
		for (i in 0...n) dispatcher.pointerMove(i, i);
		return n;
	}
}

function main():Int {
	PointerAllocationCensus.prepare();
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	var result = PointerAllocationCensus.perform(1024);
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 2;
	#end
	return result == 1024 ? 42 : 1;
}
