struct NestedStoreLeaf {
  public var tag:UInt8;
  public var delta:Int16;
  public var count:Int32;
}

struct NestedStoreRoot {
  public var prefix:Int;
  public var child:NestedStoreLeaf;
}

function main():Int {
  if (sizeof<NestedStoreLeaf>() != 8 || alignof<NestedStoreLeaf>() != 4 || offsetof<NestedStoreLeaf>("tag") != 0
    || offsetof<NestedStoreLeaf>("delta") != 2 || offsetof<NestedStoreLeaf>("count") != 4) return 1;
  if (sizeof<NestedStoreRoot>() != 12 || alignof<NestedStoreRoot>() != 4
    || offsetof<NestedStoreRoot>("prefix") != 0 || offsetof<NestedStoreRoot>("child") != 4) return 2;

  var root = new NestedStoreRoot();
  root.child.delta = cast(-1234);
  if (root.child.delta != -1234) return 3;
  var adjacent:Int = cast root.child.count;
  if (adjacent != 0) return 4;
  return 42;
}
