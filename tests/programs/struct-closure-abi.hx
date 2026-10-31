struct Vector {
  public var x:Int;
  public var y:Int;
  public var name:String;
  public function new(x:Int, y:Int, name:String) { this.x = x; this.y = y; this.name = name; }
}

class Mover {
  public var calls:Int = 0;
  public function new() {}
  public function apply(value:Vector):Vector { calls += 1; value.x += 4; return value; }
}

function shifted(value:Vector):Vector {
  value.x += 2;
  return value;
}

function run(count:Int):Int {
  var amount = 3;
  var plain:Vector->Vector = shifted;
  var captured:Vector->Vector = function(value:Vector):Vector { value.y += amount; return value; };
  var mover = new Mover(), member:Vector->Vector = mover.apply;
  var expected = "kept", original = new Vector(1, 4, expected), total = 0;
  for (i in 0...count) {
    var first = plain(original), second = captured(first), third = member(second);
    if (original.x != 1 || original.y != 4 || third.name != expected) return -1;
    total += third.x + third.y;
  }
  return mover.calls == count ? total : -1;
}

function main():Int return run(4) == 56 ? 42 : 1;
