interface NarrowRole {
}

struct NarrowLeaf {
  public var small:Int16 = 7;
}

struct NarrowRoot:NarrowRole {
  public var count:Int32 = 3;
  public var high:UInt32 = -1;
  public var nested:NarrowLeaf;
}

class NarrowKey < T > {
  public function new() {
  }
}

class Main {
  static function invoke<T>(key:NarrowKey<T>, factory:Void -> T):T {
    var value:T = factory();
    return value;
  }

  static function main():Int {
    var value:NarrowRoot = invoke(new NarrowKey<NarrowRoot>(), function() {
      var created = new NarrowRoot();
      created.nested = new NarrowLeaf();
      return created;
    }
    );
    if ((cast value.count:Int) != 3 ||(cast value.high:Int) != -1 ||(cast value.nested.small:Int) != 7) return 1;
    return 42;
  }
}
