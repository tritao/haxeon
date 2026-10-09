interface HasX {
  function xValue():Int;
}

struct Vec2:HasX {
  public var x:Int;
  public var y:Int;
  public function new(x:Int, y:Int) {
    this.x = x;
    this.y = y;
  }

  public function xValue():Int return x;
}
struct Holder {
  public var point:Vec2;
  public function new(point:Vec2) {
    this.point = point;
  }
}

struct Bounds {
  public var origin:Vec2;
  public var extent:Int;

  public function new(origin:Vec2, extent:Int) {
    this.origin = origin;
    this.extent = extent;
  }
}

@:value class LegacyPoint {
  public var x:Int;
  public function new(x:Int) this.x = x;
}

function mutate(value:Vec2):Vec2 {
  value.x = 10;
  return value;
}

function readX < T:HasX >(value:T):Int return value.xValue();

function main():Int {
  var original = new Vec2(1, 2);
  if (readX(original) != 1) return 4;
  var localCopy = original;
  localCopy.x = 3;
  if (original.x != 1 || localCopy.x != 3) return 1;
  var returned = mutate(original);
  if (original.x != 1 || returned.x != 10) return 2;
  var holder = new Holder(original);
  var holderCopy = holder;
  holderCopy.point.y = 8;
  if (holder.point.y != 2 || holderCopy.point.y != 8) return 3;
  var first = new Vec2(4, 8);
  var same = new Vec2(4, 8);
  if (!(first == same)) return 5;
  same.y = 9;
  if (first == same) return 6;
  var nestedFirst = new Bounds(new Vec2(7, 11), 13);
  var nestedSame = new Bounds(new Vec2(7, 11), 13);
  if (!(nestedFirst == nestedSame)) return 7;
  nestedSame.origin.x = 10;
  if (nestedFirst == nestedSame) return 8;
  var legacyFirst = new LegacyPoint(17);
  var legacySame = new LegacyPoint(17);
  if (!(legacyFirst == legacySame)) return 9;
  legacySame.x = 19;
  if (legacyFirst == legacySame) return 10;
  return 42;
}
