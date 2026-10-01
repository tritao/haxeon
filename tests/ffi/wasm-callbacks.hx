import WasmCallbacks;

// Native code calls Haxe closures through generated entry functions on both Wasm backends; see Callbacks.
function main():Int {
	var offset = 30;
	var combine = new combine_fnCallback(function(left:Int, right:Float,
			userData:Null<hl.Abstract<"native_pointer">>):Int return left + Std.int(right) + offset);
	if (WasmCallbacks.apply(combine, 7) != 42)
		return 1;
	var halve = new measure_fnCallback(function(node:Int, limits:size, userData:Null<hl.Abstract<"native_pointer">>):size {
		var result = new size();
		result.set_kind(node);
		result.set_width(limits.get_width() / 2);
		result.set_height(limits.get_height() / 2);
		return result;
	});
	var limits = new size();
	limits.set_width(84);
	limits.set_height(10);
	var measured = WasmCallbacks.measure(halve, limits);
	if (measured.get_kind() != 5 || measured.get_width() != 42 || measured.get_height() != 5)
		return 2;
	var failing = new combine_fnCallback(function(left:Int, right:Float, userData:Null<hl.Abstract<"native_pointer">>):Int throw "callback failed");
	WasmCallbacks.apply(failing, 1);
	if (failing.errorKind() != 1 || failing.takeError().toString() != "callback failed" || failing.errorKind() != 0)
		return 3;
	if (!combine.close() || !halve.close() || !failing.close() || combine.close())
		return 4;
	return 42;
}
