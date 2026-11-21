// A local inline function is replaced by its body at each call, as in Haxe: calling one makes no closure, and the locals it
// writes need no cell, even when it is declared in a loop.
class LocalInlineWork {
	public static function sum(values:Array<Int>):Int {
		var total = 0, scale = 3;
		inline function add(value:Int)
			total += value * scale;
		for (value in values)
			add(value);
		return total;
	}

	public static function perIteration(count:Int):Int {
		var total = 0;
		for (index in 0...count) {
			inline function square(value:Int):Int
				return value * value + index;
			total += square(index);
		}
		return total;
	}

	public static function earlyReturn(value:Int):Int {
		inline function classify(input:Int):Int {
			if (input > 2)
				return 100;
			if (input < 0)
				return -1;
			return input;
		}
		return classify(value) + classify(-value) + classify(value + 5);
	}
}

function main():Int {
	var values = [1, 2, 3], result = 0;
	result += LocalInlineWork.sum(values) + LocalInlineWork.perIteration(4) + LocalInlineWork.earlyReturn(1);
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	for (round in 0...1000)
		result += LocalInlineWork.sum(values) + LocalInlineWork.perIteration(4) + LocalInlineWork.earlyReturn(1);
	#if !wasm
	if (hl.Gc.totalAllocated() != before)
		return 2;
	#end
	// Each round adds 18 + 20 + 100 = 138.
	return result == 138 * 1001 ? 42 : 1;
}
