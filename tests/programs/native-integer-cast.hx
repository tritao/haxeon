function main():Int {
	var wide:UInt64 = cast -1;
	var low:Int = cast wide;
	var positive:UInt64 = cast 42;
	var result:Int = cast positive;
	var unsigned:UInt32 = cast -1;
	var widened:UInt64 = cast unsigned;
	var bits:haxe.Int64 = cast widened;
	return low == -1 && result == 42 && haxe.Int64.compare(bits, haxe.Int64.make(0, -1)) == 0 ? 42 : 0;
}
