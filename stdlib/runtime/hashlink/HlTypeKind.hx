package runtime.hashlink;

/** HashLink's stable numeric kind tags from hl.h. */
enum abstract HlTypeKind(Int) from Int to Int {
	var VoidType = 0;
	var UInt8Type = 1;
	var UInt16Type = 2;
	var Int32Type = 3;
	var Int64Type = 4;
	var Float32Type = 5;
	var Float64Type = 6;
	var BoolType = 7;
	var BytesType = 8;
	var DynamicType = 9;
	var Function = 10;
	var Object = 11;
	var Array = 12;
	var Type = 13;
	var Reference = 14;
	var Virtual = 15;
	var DynamicObject = 16;
	var Abstract = 17;
	var Enum = 18;
	var Nullable = 19;
	var Method = 20;
	var Struct = 21;
	var Packed = 22;
	var Guid = 23;
}
