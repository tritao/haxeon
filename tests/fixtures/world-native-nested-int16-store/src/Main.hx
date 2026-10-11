struct Leaf {
  public var tag:UInt8;
  public var delta:Int16;
  public var count:Int32;
}

struct Root {
  public var prefix:Int;
  public var child:Leaf;
}

class Main {
  static function main():Int {
    var layoutOk = sizeof<Leaf>() == 8 && alignof<Leaf>() == 4
      && offsetof<Leaf>("tag") == 0 && offsetof<Leaf>("delta") == 2 && offsetof<Leaf>("count") == 4
      && sizeof<Root>() == 12 && alignof<Root>() == 4 && offsetof<Root>("prefix") == 0 && offsetof<Root>("child") == 4;
    if (!layoutOk) {
      Sys.println("unexpected record layout");
      return 2;
    }

    var direct = new Leaf();
    direct.delta = cast(-1234);
    var directCount:Int = cast direct.count;
    if (directCount != 0) {
      Sys.println("direct Int16 store changed adjacent Int32 to " + Std.string(directCount));
      return 3;
    }

    var value = new Root();
    value.child.delta = cast(-1234);
    var nestedCount:Int = cast value.child.count;
    Sys.println("nested Int16 store left adjacent Int32 at " + Std.string(nestedCount));
    return nestedCount == 0 ? 0 : 1;
  }
}
