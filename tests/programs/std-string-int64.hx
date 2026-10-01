import haxe.Int64;

// Std.string of an Int64, directly or as a Dynamic, prints its decimal value as on HL.
function main():Int {
	var request:Int64 = Int64.make(1, 5);
	if (Std.string(request) != "4294967301")
		return 1;
	var boxed:Dynamic = Int64.neg(request);
	if (Std.string(boxed) != "-4294967301")
		return 2;
	var keys:Map<String, Int> = [];
	keys.set(Std.string(Int64.ofInt(7)), 1);
	keys.set(Std.string(Int64.ofInt(8)), 2);
	var count = 0;
	for (_ in keys.keys())
		count++;
	if (count != 2)
		return 3;
	return 42;
}
