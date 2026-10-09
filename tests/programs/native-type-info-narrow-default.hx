struct NarrowScalarDefault {
  public var value:UInt8 = 250;
}

function main():Int {
  var info = typeInfo<NarrowScalarDefault>(), field:Dynamic = info.fields[0], value:Dynamic = field.defaultValue;
  return info.size == sizeof<NarrowScalarDefault>() && info.alignment == alignof<NarrowScalarDefault>()
    && info.size == 1 && info.alignment == 1 && field.name == "value" && field.type == "native-scalar:u8"
    && field.offset == 0 && value != null && value.type == "Int" && value.value == 250 ? 42 : 1;
}
