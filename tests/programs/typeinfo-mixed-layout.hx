struct FlatRecord {
  public var x:Int;
  public var y:Int;
}

struct RichRecord {
  public var coordinate:FlatRecord;
  public var title:String;
}

function flatSize():Null < Int > return typeInfo<FlatRecord>().size;

function flatAlignment():Null < Int > return typeInfo<FlatRecord>().alignment;

function richSize():Null < Int > return typeInfo<RichRecord>().size;

function richAlignment():Null < Int > return typeInfo<RichRecord>().alignment;

function main():Int {
  var flat = typeInfo<FlatRecord>(), rich = typeInfo<RichRecord>();
  if (flat.name != "FlatRecord" || flatSize() != sizeof<FlatRecord>()
    || flatAlignment() != alignof<FlatRecord>() || flat.size == null || flat.alignment == null) return 1;
  if (flat.fields.length != 2 || flat.fields[0].offset != offsetof<FlatRecord>("x")
    || flat.fields[1].offset != offsetof<FlatRecord>("y")) return 2;
  if (richSize() != null || richAlignment() != null || rich.size != null || rich.alignment != null) return 3;
  if (rich.fields[0].size == null || rich.fields[0].alignment == null || rich.fields[0].offset != null) return 4;
  if (rich.fields[0].fields[0].offset != offsetof<FlatRecord>("x")
    || rich.fields[0].fields[1].offset != offsetof<FlatRecord>("y")) return 5;
  if (flat.hash.length != 64 || rich.hash.length != 64) return 6;
  return 42;
}
