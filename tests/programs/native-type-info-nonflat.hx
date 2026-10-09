struct InnerRecord {
  public var x:Int16;
  public var y:Int32;
}

struct ManagedPayload {
  public var title:String;
  public var position:InnerRecord;
  public var values:Array<Int>;
}

function main():Int {
  var info = typeInfo<ManagedPayload>();
  if (info.name != "ManagedPayload"
    || info.flat || info.portable || info.size != null || info.alignment != null) return 1;
  if (info.fields.length != 3 || info.fields[0].name != "title" || info.fields[0].offset != null) return 2;
  if (info.fields[1].name != "position"
    || info.fields[1].type != "class:InnerRecord<>" || info.fields[1].offset != null) return 3;
  if (!info.fields[1].flat || info.fields[1].size != 8 || info.fields[1].alignment != 4) return 4;
  if (info.fields[1].fields.length != 2
    || info.fields[1].fields[0].offset != 0 || info.fields[1].fields[1].offset != 4) return 5;
  if (info.fields[2].name != "values") return 6;
  if (info.fields[2].arguments.length != 1) return 8;
  if (info.fields[2].arguments[0].type != "Int") return 9;
  if (info.fields[2].arguments[0].flat != true) return 10;
  if (info.hash.length != 64 || info.hash != typeInfo<ManagedPayload>().hash) return 11;
  return 42;
}
