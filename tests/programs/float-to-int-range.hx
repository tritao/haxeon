// A Float converted to Int by a cast: in range it rounds toward zero; out of range, NaN included, it is what the VM's
// conversion gives on this machine, which the C of an ahead-of-time build must give too (tests/aot/programs.txt).
function truncate(value:Float):Int {
	var result:Int = cast value;
	return result;
}

function main():Int {
	if (truncate(1.5) != 1 || truncate(-1.5) != -1 || truncate(2147483647.0) != 2147483647
		|| truncate(-2147483648.0) != -2147483648)
		return 1;
	for (value in [
		2147483648.0,
		-2147483649.0,
		3e9,
		-3e9,
		1e20,
		-1e20,
		Math.POSITIVE_INFINITY,
		Math.NEGATIVE_INFINITY,
		Math.NaN
	]) {
		#if wasm
		if (truncate(value) != -2147483648 || Std.int(value) != -2147483648)
			return 2;
		#else
		Sys.println(truncate(value));
		#end
	}
	#if wasm
	var min64 = haxe.Int64.make(-2147483648, 0);
	var wide:Array<haxe.Int64> = [haxe.Int64.ofInt(0)];
	var view:Array<Dynamic> = cast wide;
	for (value in [9223372036854775808.0, -1e20, Math.POSITIVE_INFINITY, Math.NEGATIVE_INFINITY, Math.NaN]) {
		view[0] = value;
		if (haxe.Int64.fromFloat(value) != min64 || wide[0] != min64)
			return 3;
	}
	var above32 = 2147483648.5;
	var expected = haxe.Int64.make(0, -2147483648);
	view[0] = above32;
	if (haxe.Int64.fromFloat(above32) != expected || wide[0] != expected
		|| haxe.Int64.fromFloat(-1.5) != haxe.Int64.ofInt(-1))
		return 4;
	#end
	return 42;
}
