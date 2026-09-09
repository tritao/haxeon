package runtime;

/** Scalar and pointer kinds accepted by the ordinary C ABI call bridge. */
enum abstract NativeType(Int) to Int {
	var Void = 0;
	var I8 = 1;
	var U8 = 2;
	var I16 = 3;
	var U16 = 4;
	var I32 = 5;
	var U32 = 6;
	var I64 = 7;
	var U64 = 8;
	var F32 = 9;
	var F64 = 10;
	var Pointer = 11;
}
