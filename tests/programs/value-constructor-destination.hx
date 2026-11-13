struct ConstructorLeaf {
  public var x:Int;
  public var name:String;
  public var optional:Null<Int>;
  public function new(x:Int, name:String, optional:Null<Int>) {
    this.x = x;
    this.name = name;
    this.optional = optional;
  }
}
struct ConstructorBranch {
  public var leaf:ConstructorLeaf;
  public var y:Int;
  public function new(leaf:ConstructorLeaf, y:Int, fail:Bool) {
    this.leaf = leaf;
    if (fail) throw "failed";
    this.y = y;
  }
}
struct ConstructorRecord {
  public final a:Int;
  public final b:Int;
  public final c:Int;
  public final d:Int;
  public final e:Int;
  public final f:Int;
  public function new(items:Array<Int>) {
    a = items == null ? 0 : items[0];
    b = items == null ? 0 : items[0];
    c = items == null ? 0 : items[0];
    d = items == null ? 0 : items[0];
    e = items == null ? 0 : items[0];
    f = items == null ? 0 : items[0];
  }
}
struct ConstructorDefaults {
  public var x:Int;
  public var y:Int;
}
struct ConstructorEarly {
  public var x:Int;
  public var y:Int;
  public function new(x:Int) {
    this.x = x;
    if (x < 0) return;
    this.y = x + 1;
  }
}
class ConstructorOwner {
  var record:ConstructorRecord;
  public function new() {
  }
  public function install(items:Array<Int>):Void record = new ConstructorRecord(items);
  public function read():Int return record.a + record.b + record.c + record.d + record.e + record.f;
}
class ConstructorHolder {
  public var branch:ConstructorBranch;
  public function new() branch = new ConstructorBranch(new ConstructorLeaf(4, "field", 2), 6, false);
}
class ValueConstructorDestination {
  static var owners:Array<ConstructorOwner>;
  static var items:Array<Int>;
  public static function prepare(count:Int):Void {
    owners = [for (_ in 0...count) new ConstructorOwner()];
    items = [1];
  }
  public static function perform(count:Int):Int {
    var sum = 0;
    for (index in 0...count) {
      owners[index].install(items);
      sum += owners[index].read();
    }
    return sum;
  }
  static function main():Int {
    var defaults = new ConstructorDefaults();
    if (defaults.x != 0 || defaults.y != 0) return 11;
    var early = new ConstructorEarly(-3);
    var normal = new ConstructorEarly(7);
    if (early.x != -3 || early.y != 0 || normal.x != 7 || normal.y != 8) return 10;
    var values = [new ConstructorBranch(new ConstructorLeaf(3, "alive", 7), 5, false)];
    values[0] = new ConstructorBranch(
      new ConstructorLeaf(values[0].y, values[0].leaf.name, null),
      values[0].leaf.x,
      false
    );
    if (values[0].leaf.x != 5
      || values[0].y != 3 || values[0].leaf.name != "alive" || values[0].leaf.optional != null) return 1;
    try {
      values[0] = new ConstructorBranch(new ConstructorLeaf(9, "bad", 9), 9, true);
      return 2;
    } catch (error:Dynamic) {
    }
    if (values[0].leaf.x != 5
      || values[0].y != 3 || values[0].leaf.name != "alive" || values[0].leaf.optional != null) return 3;
    var holder = new ConstructorHolder();
    holder.branch = new ConstructorBranch(
      new ConstructorLeaf(holder.branch.y, holder.branch.leaf.name, null),
      holder.branch.leaf.x,
      false
    );
    try {
      holder.branch = new ConstructorBranch(new ConstructorLeaf(9, "bad", 9), 9, true);
      return 7;
    } catch (error:Dynamic) {
    }
    if (holder.branch.leaf.x != 6
      || holder.branch.y != 4 || holder.branch.leaf.name != "field" || holder.branch.leaf.optional != null) return 8;
    var erased:Dynamic = new ConstructorLeaf(11, "erased", 1);
    var restored:ConstructorLeaf = cast erased;
    if (restored.x != 11 || restored.name != "erased" || restored.optional != 1) return 9;
    prepare(8);
    if (perform(8) != 48) return 4;
    prepare(1024);
    #if !wasm
    var census = Sys.getEnv("VALUE_CONSTRUCTOR_CENSUS");
    hl.Gc.censusReset();
    hl.Gc.censusStart(0);
    var before = hl.Gc.totalAllocated();
    #end
    var result = perform(1024);
    #if !wasm
    var bytes = hl.Gc.totalAllocated() - before;
    hl.Gc.censusStop();
    if (census != null) hl.Gc.censusDump(census);
    if (bytes != 0) return 5;
    #end
    return result == 6144 ? 42 : 6;
  }
}
