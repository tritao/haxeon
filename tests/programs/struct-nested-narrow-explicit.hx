struct NarrowLeaf {
  public var small:Int16 = 7;
}

struct NarrowRoot {
  public var count:Int32 = 3;
  public var high:UInt32 = -1;
  public var nested:NarrowLeaf;
}

function main():Int {
  var leaf = new NarrowLeaf();
  leaf.small = cast(-1234);
  var value = new NarrowRoot();
  value.nested = leaf;
  var extracted = value.nested;
  extracted.small = cast(99);
  if ((cast value.count:Int) != 3 ||(cast value.high:Int) != -1) return 1;
  if ((cast value.nested.small:Int) != -1234 ||(cast extracted.small:Int) != 99) return 2;
  return 42;
}
