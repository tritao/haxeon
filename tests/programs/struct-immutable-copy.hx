struct Point : Hashable {
  public final x:Int;
  public final y:Int;
  public function new(x:Int, y:Int) {
    this.x = x;
    this.y = y;
  }
}

struct Bounds : Equatable {
  public final origin:Point;
  public final extent:Int;
  public function new(origin:Point, extent:Int) {
    this.origin = origin;
    this.extent = extent;
  }
}

struct MutablePoint : Diffable {
  public var x:Int;
  public function new(x:Int) this.x = x;
}

class Counter {
  public var calls:Int = 0;
  public function new() {}
  public function point():Point {
    calls++;
    return new Point(17, 25);
  }
}

function identity<T>(value:T):T return value;

function main():Int {
  var counter = new Counter();
  var point = counter.point();
  if (counter.calls != 1 || point.x + point.y != 42) return 1;
  var copy = identity(point);
  if (!(copy == point) || !haxeon.Equality.equals(copy, point)) return 2;
  if (haxeon.Hashing.hash(copy) != haxeon.Hashing.hash(point)) return 3;
  var bounds = new Bounds(point, 9);
  var boundsCopy = bounds;
  if (!(bounds == boundsCopy) || boundsCopy.origin.x != 17) return 4;
  var mutable = new MutablePoint(7);
  var mutableCopy = mutable;
  mutableCopy.x = 11;
  if (mutable.x != 7 || mutableCopy.x != 11) return 5;
  var mask = haxeon.Diff.apply(mutable, mutableCopy, new MutablePoint(13));
  if (mask != 1 || mutable.x != 13 || mutableCopy.x != 11) return 6;
  mutable.x += 3;
  if (++mutable.x != 17 || mutable.x++ != 17 || mutable.x != 18) return 7;
  // Pure methods remain usable on returned values.
  return 42;
}
