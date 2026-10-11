struct NarrowLeaf {
  public var small:Int16 = 7;
}

struct NarrowRoot {
  public var count:Int32 = 3;
  public var high:UInt32 = -1;
  public var nested:NarrowLeaf;
}

function main():Int {
  var value = new NarrowRoot();
  if ((cast value.count:Int) != 3 ||(cast value.high:Int) != -1) return 1;
  if ((cast value.nested.small:Int) != 0) return 2;
  return 42;
}
