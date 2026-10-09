struct Point {
  public var x:Int;
  public var y:Float;

  public function new(x:Int, y:Float) {
    this.x = x;
    this.y = y;
  }
}

struct Envelope {
  public var enabled:Bool;
  public var point:Point;
  public var tail:Int;

  public function new(enabled:Bool, point:Point, tail:Int) {
    this.enabled = enabled;
    this.point = point;
    this.tail = tail;
  }
}

function main():Int {
  if (sizeof<Point>() != 16 || alignof<Point>() != 8 || offsetof<Point>("y") != 8) return 1;
  if (sizeof<Envelope>() != 32
    || alignof<Envelope>() != 8 || offsetof<Envelope>("point") != 8 || offsetof<Envelope>("tail") != 24) return 2;
  var source = new Envelope(true, new Point(20, 2.5), 9);
  var copy = source;
  copy.point.x = 21;
  if (!source.enabled || source.point.x != 20 || copy.point.x != 21 || copy.tail != 9) return 3;
  return 42;
}
