class InheritedBase<T> {
  public final base:T;
  public function new(base:T) this.base = base;
}
class InheritedKey extends InheritedBase<Int> implements Hashable {
  public final child:Int;
  public function new(base:Int, child:Int) { super(base); this.child = child; }
}
class InheritedEditableBase {
  public var base:Int;
  public function new(base:Int) this.base = base;
}
class InheritedEditable extends InheritedEditableBase implements Diffable {
  public var child:Int;
  public function new(base:Int, child:Int) { super(base); this.child = child; }
}
class InheritedCopyBase {
  public var base:Int = 0;
  public function new() {}
}
class InheritedCopy extends InheritedCopyBase implements Diffable {
  public var child:Int = 0;
  public function new() super();
}
class InheritedCustomBase implements Hashable {
  public final value:Int;
  public function new(value:Int) this.value = value;
  public function equals(other:InheritedCustomBase):Bool return value % 10 == other.value % 10;
  public function hash():Int return value % 10;
}
class InheritedCustom extends InheritedCustomBase {
  public final extra:Int;
  public function new(value:Int, extra:Int) { super(value); this.extra = extra; }
}
function main():Int {
  var a = new InheritedKey(1, 4), b = new InheritedKey(2, 4), c = new InheritedKey(1, 4);
  if (haxeon.Equality.equals(a, b) || !haxeon.Equality.equals(a, c)) return 1;
  if (haxeon.Hashing.hash(a) == haxeon.Hashing.hash(b) || haxeon.Hashing.hash(a) != haxeon.Hashing.hash(c)) return 2;
  var before = new InheritedEditable(1, 4), after = new InheritedEditable(2, 5), target = new InheritedEditable(1, 4);
  if (haxeon.Diff.mask(before, after) != 3 || haxeon.Diff.bit(InheritedEditable, "base") != 1
      || haxeon.Diff.bit(InheritedEditable, "child") != 2 || haxeon.Diff.all(InheritedEditable) != 3) return 3;
  if (haxeon.Diff.apply(target, before, after) != 3 || target.base != 2 || target.child != 5) return 4;
  if (haxeon.Diff.fingerprint(before) == haxeon.Diff.fingerprint(new InheritedEditable(2, 4))) return 5;
  var original = new InheritedCopy(); original.base = 3; original.child = 8;
  var copy = haxeon.Diff.copy(original);
  if (copy.base != 3 || copy.child != 8 || copy == original) return 7;
  var x = new InheritedCustom(1, 3), y = new InheritedCustom(11, 9);
  if (!haxeon.Equality.equals(x, y) || haxeon.Hashing.hash(x) != haxeon.Hashing.hash(y)) return 6;
  return 42;
}
