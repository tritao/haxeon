import haxe.io.FPHelper;

// FPHelper converts floats and doubles to and from their IEEE 754 bits as Haxe does, on every target.
function main():Int {
	if (FPHelper.floatToI32(1.0) != 0x3F800000 || FPHelper.floatToI32(-2.5) != 0xC0200000
		|| FPHelper.i32ToFloat(0x40000000) != 2.0)
		return 1;
	// A double is rounded to the nearest 32-bit float.
	if (FPHelper.i32ToFloat(FPHelper.floatToI32(0.1)) == 0.1
		|| Math.abs(FPHelper.i32ToFloat(FPHelper.floatToI32(0.1)) - 0.1) > 1e-8)
		return 2;
	if (haxe.Int64.toStr(FPHelper.doubleToI64(1.0)) != "4607182418800017408"
		|| FPHelper.i64ToDouble(0, 0x3FF00000) != 1.0)
		return 3;
	return 42;
}
