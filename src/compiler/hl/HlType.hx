package compiler.hl;

/** HashLink type tags as serialized in an HLB file. */
enum abstract HlType(Int) from Int to Int {
    var Void = 0;
    var Ui8 = 1;
    var Ui16 = 2;
    var I32 = 3;
    var I64 = 4;
    var F32 = 5;
    var F64 = 6;
    var Bool = 7;
    var Bytes = 8;
    var Dyn = 9;
    var Fun = 10;
    var Obj = 11;
    var Array = 12;
    var Type = 13;
    var Ref = 14;
    var Virtual = 15;
    var DynObj = 16;
    var Abstract = 17;
    var Enum = 18;
    var Null = 19;
    var Method = 20;
    var Struct = 21;
    var Packed = 22;
    var Guid = 23;
}
