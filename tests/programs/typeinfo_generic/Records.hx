package typeinfo_generic;

struct FlatRecord {
  public var x:Int;
  public var y:Int;
}

struct Rich {
  public var coordinate:FlatRecord;
  public var title:String;
}
