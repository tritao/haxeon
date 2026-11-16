// Int64.low and .high are the low and high 32 bits, as in Haxe.
function bits():haxe.Int64 return haxe.Int64.make(0x12345678, -2);
function main():Int {
	var value = bits();
	return value.low == -2 && value.high == 0x12345678 && haxe.Int64.make(-1, 5).high == -1 ? 42 : 1;
}
