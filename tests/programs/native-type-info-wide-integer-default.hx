struct NativeIntegerWidthDefaultProbe {
  public var signed:Int32 = 123456789;
  public var unsigned:UInt32 = 0;
  public var highBit:UInt32 = -1;
}

function main():Int {
  var info = typeInfo<NativeIntegerWidthDefaultProbe>(), signed:Dynamic = info.fields[0].defaultValue,
    unsigned:Dynamic = info.fields[1].defaultValue, highBit:Dynamic = info.fields[2].defaultValue;
  if (info.size != 12 || info.alignment != 4 || info.fields.length != 3) return 1;
  if (info.fields[0].type != "native-scalar:i32"
    || info.fields[0].offset != 0 || signed == null || signed.type != "Int" || signed.value != 123456789) return 2;
  if (info.fields[1].type != "native-scalar:u32"
    || info.fields[1].offset != 4 || unsigned == null || unsigned.type != "Int" || unsigned.value != 0) return 3;
  if (info.fields[2].type != "native-scalar:u32"
    || info.fields[2].offset != 8 || highBit == null || highBit.type != "Int" || highBit.value != -1) return 4;
  return 42;
}
