struct InnerRecord {
  @:Range(-1.5, 4.25) public var x:Int16;
  @:Replicate(owner) public var y:Int32;
}
@:annotation struct Range {
  public var min:Float;
  public var max:Float;
}
@:annotation enum abstract Replicate(Int) {
  var all = 1;
  var owner = 2;
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
  var range = info.fields[1].fields[0].annotationValues[0];
  if (range.name != "Range" || range.arguments.length != 2
    || range.arguments[0].name != "min" || range.arguments[0].type != "Float" || range.arguments[0].value != -1.5
    || range.arguments[1].name != "max" || range.arguments[1].value != 4.25) return 12;
  var replicate = info.fields[1].fields[1].annotationValues[0];
  if (replicate.name != "Replicate" || replicate.arguments.length != 1
    || replicate.arguments[0].type != "Int" || replicate.arguments[0].value != 2) return 13;
  if (info.fields[2].name != "values") return 6;
  if (info.fields[2].arguments.length != 1) return 8;
  if (info.fields[2].arguments[0].type != "Int") return 9;
  if (info.fields[2].arguments[0].flat != true) return 10;
  if (info.hash.length != 64 || info.hash != typeInfo<ManagedPayload>().hash) return 11;
  return 42;
}
