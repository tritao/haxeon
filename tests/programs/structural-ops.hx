import haxeon.Diff;

class Point {
  public var x:Float;
  public var y:Float;

  public function new() {
    x = 0.0;
    y = 0.0;
  }
}

enum abstract Mode(Int) {
  var Plain = 1;
  var Bold = 2;
}

class Style implements Diffable {
  public var width:Int = 0;
  public var visible:Bool = true;
  public var mode:Mode = Plain;
  public var name:Null<String> = null;
  public var origin:Point;
  public var scale:Float = 1.0;

  public function new() {
    origin = new Point();
  }
}

/** Copy, equality, hash, masks and the change delta, all generated from Style's six fields. */
function main():Int {
  var a = new Style();
  a.width = 3;
  a.origin.x = 2.5;
  a.name = "n";
  var b = Diff.copy(a);
  if (b == a) return 1;
  if (Diff.mask(a, b) != 0) return 2;
  // Shallow: the nested instance is shared.
  if (b.origin != a.origin) return 3;
  b.width = 4;
  b.mode = Bold;
  var mask = Diff.mask(a, b);
  if (mask != (Diff.bit(\Style.width) | Diff.bit(\Style.mode))) return 5;
  if (Diff.mask(a, b) == 0) return 6;
  // A field changed outside the delta is left alone.
  var target = Diff.copy(a);
  target.visible = false;
  var applied = Diff.apply(target, a, b);
  if (applied != mask || target.width != 4 || target.mode != Bold || target.visible) return 7;
  if (Diff.all(Style) != 63) return 8;
  var p = new Point(), q = new Point();
  q.y = 1.0;
  if (p == q) return 9;
  // Replacing a reference field changes identity even when its fields match.
  var c = Diff.copy(a);
  c.origin = new Point();
  c.origin.x = 2.5;
  if (Diff.mask(a, c) != Diff.bit(\Style.origin)) return 10;
  var nulled = Diff.copy(a);
  nulled.name = null;
  if (Diff.mask(a, nulled) == 0 || Diff.mask(a, nulled) != Diff.bit(\Style.name)) return 11;
  return 42;
}
