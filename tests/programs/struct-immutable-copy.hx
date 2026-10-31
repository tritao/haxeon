@:structural struct Point {
  public final x:Int;
  public final y:Int;
  public function new(x:Int, y:Int) {
    this.x = x;
    this.y = y;
  }
}

struct Bounds {
  public final origin:Point;
  public final extent:Int;
  public function new(origin:Point, extent:Int) {
    this.origin = origin;
    this.extent = extent;
  }
}

struct MutablePoint {
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
  var point = haxeon.Structural.copy(counter.point());
  if (counter.calls != 1 || point.x + point.y != 42) return 1;
  var copy = identity(haxeon.Structural.copy(point));
  if (!(copy == point) || !haxeon.Equality.equals(copy, point)) return 2;
  if (haxeon.Structural.hash(copy) != haxeon.Structural.hash(point)) return 3;
  var bounds = new Bounds(point, 9);
  var boundsCopy = haxeon.Structural.copy(bounds);
  if (!(bounds == boundsCopy) || boundsCopy.origin.x != 17) return 4;
  var mutable = new MutablePoint(7);
  var mutableCopy = haxeon.Structural.copy(mutable);
  mutableCopy.x = 11;
  if (mutable.x != 7 || mutableCopy.x != 11) return 5;
  var mask = haxeon.Structural.assignChanged(mutable, mutableCopy, new MutablePoint(13));
  if (mask != 1 || mutable.x != 13 || mutableCopy.x != 11) return 6;
  mutable.x += 3;
  if (++mutable.x != 17 || mutable.x++ != 17 || mutable.x != 18) return 7;
  // Pure methods remain usable on returned values.
  return 42;
}
